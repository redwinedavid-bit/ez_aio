local __object_safety=require("shared/object_safety")
-- Auto Herbing Module (Shared)
-- Provides automatic herb gathering functionality for all rotations

local auto_herbing = {}

-- ============================================================================
-- MODULE IMPORTS
-- ============================================================================

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

-- ============================================================================
-- HERB DEFINITIONS (GameObject IDs)
-- ============================================================================

local herb_ids = {
    -- Classic
    [1617] = true,  -- Silverleaf
    [1618] = true,  -- Peacebloom
    [1619] = true,  -- Earthroot
    [1620] = true,  -- Mageroyal
    [1621] = true,  -- Briarthorn
    [1622] = true,  -- Bruiseweed
    [1623] = true,  -- Wild Steelbloom
    [1624] = true,  -- Kingsblood
    [1628] = true,  -- Grave Moss
    [2040] = true,  -- Stranglekelp (shared ID in some implementations)
    [2041] = true,  -- Liferoot
    [2042] = true,  -- Fadeleaf
    [2043] = true,  -- Khadgar's Whisker
    [2866] = true,  -- Firebloom
    [142140] = true, -- Purple Lotus
    [142141] = true, -- Arthas' Tears
    [142142] = true, -- Sungrass
    [142143] = true, -- Blindweed
    [142144] = true, -- Ghost Mushroom
    [142145] = true, -- Gromsblood
    [176583] = true, -- Golden Sansam
    [176584] = true, -- Dreamfoil
    [176586] = true, -- Mountain Silversage
    [176587] = true, -- Plaguebloom
    [176588] = true, -- Icecap
    [176589] = true, -- Black Lotus

    -- TBC (Outland)
    [181270] = true, -- Felweed
    [183044] = true, -- Felweed (alternate)
    [181271] = true, -- Dreaming Glory
    [183045] = true, -- Dreaming Glory (alternate)
    [181275] = true, -- Ragveil
    [183043] = true, -- Ragveil (alternate)
    [181277] = true, -- Terocone
    [181276] = true, -- Flame Cap
    [181278] = true, -- Ancient Lichen
    [181279] = true, -- Netherbloom
    [181280] = true, -- Nightmare Vine
    [181281] = true, -- Mana Thistle
    [185881] = true  -- Netherdust Bush
}

-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

local last_herb_time = 0.0

local object_cache = {
    objects = {},
    last_update = 0.0,
    refresh_interval = 0.5
}

-- ============================================================================
-- PRIVATE HELPER FUNCTIONS
-- ============================================================================

---@param obj game_object
---@return boolean
local function safe_is_valid(obj)
    if not obj then
        return false
    end

    local ok, result = pcall(function()
        return obj:is_valid()
    end)

    return ok and result == true
end

local function get_cached_objects()
    local now = core.time()
    if (now - object_cache.last_update) >= object_cache.refresh_interval then
        object_cache.objects = core.object_manager.get_all_objects()
        object_cache.last_update = now
    end
    return object_cache.objects
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

---Set custom herb IDs for herbing
---@param herb_table table
function auto_herbing:set_herb_ids(herb_table)
    if type(herb_table) == "table" then
        herb_ids = herb_table
    end
end

---Main auto-herbing function
---@param local_player game_object
---@param menu_elements table
---@return boolean
function auto_herbing:on_update(local_player, menu_elements)
    if not local_player then
        return false
    end

    if local_player:is_mounted() then
        return false
    end

    if not menu_elements or not menu_elements.auto_herb_enabled then
        return false
    end

    if not menu_elements.auto_herb_enabled:get_state() then
        return false
    end

    if unit_helper:is_in_combat(local_player) then
        return false
    end

    if local_player:is_moving() then
        return false
    end

    local cast_end_time = local_player:get_active_spell_cast_end_time()
    if cast_end_time and cast_end_time > 0.0 then
        return false
    end

    local channel_end_time = local_player:get_active_channel_cast_end_time()
    if channel_end_time and channel_end_time > 0.0 then
        return false
    end

    local now = core.time()
    if (now - last_herb_time) < 0.5 then
        return false
    end

    local player_pos = local_player:get_position()
    if not player_pos then
        return false
    end

    local range = menu_elements.auto_herb_range and menu_elements.auto_herb_range:get() or 5
    local all_objects = get_cached_objects()

    for _, obj in __object_safety.live_ipairs(all_objects) do
        if not safe_is_valid(obj) then
            goto continue
        end

        if obj:is_unit() then
            goto continue
        end

        local object_id = nil
        local ok_item, item_id = pcall(function()
            return obj:get_item_id()
        end)
        if ok_item then
            object_id = item_id
        end
        if not object_id then
            local ok_npc, npc_id = pcall(function()
                return obj:get_npc_id()
            end)
            if ok_npc then
                object_id = npc_id
            end
        end

        if not object_id or herb_ids[object_id] ~= true then
            goto continue
        end

        local obj_pos = obj:get_position()
        if not obj_pos then
            goto continue
        end

        if obj_pos:dist_to_ignore_z(player_pos) > range then
            goto continue
        end

        local ok_use, success = pcall(function()
            return core.input.use_object(obj)
        end)

        if ok_use and success == true then
            last_herb_time = now
            return true
        end

        ::continue::
    end

    return false
end

---Optional menu rendering helper
---@param menu_elements table
function auto_herbing:on_menu_render(menu_elements)
    if not menu_elements then
        return
    end

    if menu_elements.auto_herb_enabled then
        menu_elements.auto_herb_enabled:render("Enable Auto Herbing")
    end

    if menu_elements.auto_herb_enabled and menu_elements.auto_herb_enabled:get_state() then
        if menu_elements.auto_herb_range then
            menu_elements.auto_herb_range:render("Herbing Range (yards)")
        end
    end
end

return auto_herbing
