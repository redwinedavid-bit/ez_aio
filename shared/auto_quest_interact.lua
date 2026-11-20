local __object_safety=require("shared/object_safety")
-- Auto Quest Interact Module (Shared)
-- Provides automatic quest object interaction functionality for all rotations
-- Requires Questie addon integration via questie_tracker module

local auto_quest_interact = {}

-- ============================================================================
-- MODULE IMPORTS
-- ============================================================================

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type questie_tracker|nil
local questie_tracker = nil
do
    local ok_questie, questie_module = pcall(require, "common/utility/questie_tracker")
    if ok_questie then
        questie_tracker = questie_module
    end
end

-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

local last_quest_interact_time = 0.0
local last_quest_interact_object_id = nil

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

---Check if Questie tracker is available and hooked
---@return boolean
function auto_quest_interact:is_available()
    return questie_tracker ~= nil and questie_tracker.is_hooked and questie_tracker:is_hooked()
end

---Main auto-quest-interact function
---@param local_player game_object
---@param menu_elements table
---@return boolean
function auto_quest_interact:on_update(local_player, menu_elements)
    if not local_player then
        return false
    end

    if not menu_elements or not menu_elements.auto_quest_interact_enabled then
        return false
    end

    if not menu_elements.auto_quest_interact_enabled:get_state() then
        return false
    end

    if not questie_tracker or not questie_tracker.is_hooked or not questie_tracker:is_hooked() then
        return false
    end

    if unit_helper:is_in_combat(local_player) then
        return false
    end

    if local_player:is_mounted() then
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
    if (now - last_quest_interact_time) < 0.5 then
        return false
    end

    local player_pos = local_player:get_position()
    if not player_pos then
        return false
    end

    local range = menu_elements.auto_quest_interact_range and menu_elements.auto_quest_interact_range:get() or 4
    local all_objects = get_cached_objects()

    local best_obj = nil
    local best_distance = nil

    for _, obj in __object_safety.live_ipairs(all_objects) do
        if not obj or not obj:is_valid() then
            goto continue
        end

        if obj:is_unit() then
            goto continue
        end

        local ok_use, can_use = pcall(function()
            return obj:can_be_used()
        end)
        if not ok_use or not can_use then
            goto continue
        end

        local ok_q, is_quest_object = pcall(function()
            return questie_tracker:is_quest_object(obj)
        end)
        if not ok_q or not is_quest_object then
            goto continue
        end

        local obj_pos = obj:get_position()
        if not obj_pos then
            goto continue
        end

        local distance = obj_pos:dist_to_ignore_z(player_pos)
        if distance > range then
            goto continue
        end

        local obj_id = safe_object_id(obj)
        if obj_id and last_quest_interact_object_id and obj_id == last_quest_interact_object_id and (now - last_quest_interact_time) < 2.0 then
            goto continue
        end

        if not best_distance or distance < best_distance then
            best_obj = obj
            best_distance = distance
        end

        ::continue::
    end

    if not best_obj then
        return false
    end

    local ok_interact, success = pcall(function()
        return core.input.use_object(best_obj)
    end)

    if ok_interact and success then
        last_quest_interact_time = now
        last_quest_interact_object_id = safe_object_id(best_obj)
        return true
    end

    return false
end

---Optional menu rendering helper
---@param menu_elements table
function auto_quest_interact:on_menu_render(menu_elements)
    if not menu_elements then
        return
    end

    if not auto_quest_interact:is_available() then
        return
    end

    if menu_elements.auto_quest_interact_enabled then
        menu_elements.auto_quest_interact_enabled:render("Enable Auto Quest Interact")
    end

    if menu_elements.auto_quest_interact_enabled and menu_elements.auto_quest_interact_enabled:get_state() then
        if menu_elements.auto_quest_interact_range then
            menu_elements.auto_quest_interact_range:render("Interact Range (yards)")
        end
    end
end

return auto_quest_interact
