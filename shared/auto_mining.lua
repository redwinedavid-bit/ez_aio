local __object_safety=require("shared/object_safety")
-- Auto Mining Module (Shared)
-- Provides automatic mining functionality for all rotations

local auto_mining = {}

-- ============================================================================
-- MODULE IMPORTS
-- ============================================================================

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

-- ============================================================================
-- ORE DEFINITIONS
-- ============================================================================

local ore_ids = {
    [1731] = true,   -- Copper
    [1732] = true,   -- Tin
    [1733] = true,   -- Iron
    [1735] = true,   -- Gold
    [1734] = true,   -- Mithril
    [2040] = true,   -- Silver
    [2047] = true,   -- Gold (alternate)
    [324] = true,    -- Thorium

    -- TBC (Outland)
    [181555] = true, -- Fel Iron Deposit
    [181556] = true, -- Adamantite Deposit
    [181557] = true, -- Khorium Vein
    [181569] = true, -- Rich Adamantite Deposit
    [181570] = true, -- Rich Adamantite Deposit (alternate spawn)
    [185877] = true, -- Nethercite Deposit (rare)
}

-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

local last_mine_time = 0.0

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

    return ok and result
end

---@param obj game_object
---@return string|nil
local function safe_object_id(obj)
    if not safe_is_valid(obj) then
        return nil
    end

    local ok_pos, pos = pcall(function()
        return obj:get_position()
    end)

    local ok_npc, npc_id = pcall(function()
        return obj:get_npc_id()
    end)

    if ok_pos and pos and ok_npc and npc_id and npc_id > 0 then
        local quant = 2.0 -- 0.5 yard grid to avoid float jitter
        local qx = math.floor((pos.x * quant) + 0.5)
        local qy = math.floor((pos.y * quant) + 0.5)
        local qz = math.floor((pos.z * quant) + 0.5)
        return string.format("npc:%d:%d:%d:%d", npc_id, qx, qy, qz)
    end

    local ok_tostring, obj_id = pcall(function()
        return tostring(obj)
    end)
    if ok_tostring and obj_id then
        return obj_id
    end

    return nil
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

---Set custom ore IDs for mining
---@param ore_table table
function auto_mining:set_ore_ids(ore_table)
    if type(ore_table) == "table" then
        ore_ids = ore_table
    end
end

---Main auto-mining function
---@param local_player game_object
---@param menu_elements table
---@return boolean
function auto_mining:on_update(local_player, menu_elements)
    if not local_player then
        return false
    end

    if local_player:is_mounted() then
        return false
    end

    if not menu_elements or not menu_elements.auto_mine_enabled then
        return false
    end

    if not menu_elements.auto_mine_enabled:get_state() then
        return false
    end

    if unit_helper:is_in_combat(local_player) then
        return false
    end

    if local_player:is_moving() then
        return false
    end

    local cast_end_time = local_player:get_active_spell_cast_end_time()
    if cast_end_time > 0.0 then
        return false
    end

    local channel_end_time = local_player:get_active_channel_cast_end_time()
    if channel_end_time > 0.0 then
        return false
    end

    local now = core.time()
    if (now - last_mine_time) < 0.5 then
        return false
    end

    local player_pos = local_player:get_position()
    if not player_pos then
        return false
    end

    local range = menu_elements.auto_mine_range and menu_elements.auto_mine_range:get() or 5
    local all_objects = get_cached_objects()

    for _, obj in __object_safety.live_ipairs(all_objects) do
        if not obj or not obj:is_valid() then
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

        if not object_id or not ore_ids[object_id] then
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

        if ok_use and success then
            last_mine_time = now
            return true
        end

        ::continue::
    end

    return false
end

---Optional menu rendering helper
---@param menu_elements table
function auto_mining:on_menu_render(menu_elements)
    if not menu_elements then
        return
    end

    if menu_elements.auto_mine_enabled then
        menu_elements.auto_mine_enabled:render("Enable Auto Mining")
    end

    if menu_elements.auto_mine_enabled and menu_elements.auto_mine_enabled:get_state() then
        if menu_elements.auto_mine_range then
            menu_elements.auto_mine_range:render("Mining Range (yards)")
        end
    end
end

return auto_mining
