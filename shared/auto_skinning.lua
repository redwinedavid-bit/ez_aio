local __object_safety=require("shared/object_safety")
-- Auto Skinning Module (Shared)
-- Provides automatic skinning functionality for all rotations
-- Classic Era + Classic TBC compatible (relies on can_be_skinned() for final eligibility)

local auto_skinning = {}

-- ============================================================================
-- MODULE IMPORTS
-- ============================================================================

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

-- ============================================================================
-- SKINNING SPELL IDS (Classic Era + TBC)
-- ============================================================================

-- Ordered from highest to lowest skill for optimal detection
local skinning_spell_ids = {
    8618,  -- Skinning (Artisan, 225-300 skill)
    8617,  -- Skinning (Expert, 150-225 skill)
    8613,  -- Skinning (base, up to 150 skill)

    -- Passive training spells (profession ranks)
    10769, -- Artisan Skinning (225-300 skill)
    8619,  -- Expert Skinning (150-225 skill)
    3275,  -- Journeyman Skinning (75-150 skill)
    3274,  -- Apprentice Skinning (1-75 skill)
}

-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

local last_skin_time = 0.0

local object_cache = {
    objects = {},
    last_update = 0.0,
    refresh_interval = 0.5
}

-- Skinned corpse tracking (prevents re-attempting same corpse)
local skinned_corpses = {}
local MAX_SKINNED_CORPSES_SIZE = 500

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

---@param menu_elements table
local function clear_skinned_tracking_if_needed(menu_elements)
    local now = core.time()

    -- Cleanup interval: 120 seconds (corpses despawn after ~2 minutes)
    local cleanup_interval = 120
    local force_cleanup = #skinned_corpses > MAX_SKINNED_CORPSES_SIZE

    if not force_cleanup and (now - (object_cache.last_cleanup or 0.0)) < cleanup_interval then
        return
    end

    object_cache.last_cleanup = now

    -- Clean skinned corpses list
    for i = #skinned_corpses, 1, -1 do
        local entry = skinned_corpses[i]
        if not entry or not entry.id then
            table.remove(skinned_corpses, i)
        elseif entry.time and entry.time > 0 and (now - entry.time) > cleanup_interval then
            table.remove(skinned_corpses, i)
        end
    end
end

---@param corpse game_object
---@return boolean
local function has_been_skinned(corpse)
    local corpse_id = safe_object_id(corpse)
    if not corpse_id then
        return false
    end

    for _, entry in ipairs(skinned_corpses) do
        if entry and entry.id == corpse_id then
            return true
        end
    end

    return false
end

---@param corpse game_object
local function mark_as_skinned(corpse)
    local corpse_id = safe_object_id(corpse)
    if not corpse_id then
        return
    end

    -- Check if already marked
    for _, entry in ipairs(skinned_corpses) do
        if entry and entry.id == corpse_id then
            entry.time = core.time()  -- Update timestamp
            return
        end
    end

    -- Add new entry
    table.insert(skinned_corpses, {
        id = corpse_id,
        time = core.time()
    })
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

---Check if player has learned Skinning profession
---@return boolean
function auto_skinning:is_available()
    if not core or not core.spell_book or not core.spell_book.is_spell_learned then
        return false
    end

    -- Best-effort: these IDs exist on Classic clients; on other clients, eligibility is still
    -- determined by obj:can_be_skinned() during scanning.
    for _, spell_id in ipairs(skinning_spell_ids) do
        local ok, learned = pcall(function() return core.spell_book.is_spell_learned(spell_id) end)
        if ok and learned then
            return true
        end
    end

    return false
end

---Main auto-skinning function
---@param local_player game_object
---@param menu_elements table
---@return boolean
function auto_skinning:on_update(local_player, menu_elements)
    if not local_player then
        return false
    end

    if local_player:is_mounted() then
        return false
    end

    if not menu_elements or not menu_elements.auto_skin_enabled then
        return false
    end

    if not menu_elements.auto_skin_enabled:get_state() then
        return false
    end

    -- Do not hard-block on spell ID detection: on Classic TBC the client/profession spells can differ.
    -- Final eligibility is verified per-corpse via obj:can_be_skinned().

    -- Out of combat only (safety-first approach)
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
    if (now - last_skin_time) < 0.5 then
        return false
    end

    local player_pos = local_player:get_position()
    if not player_pos then
        return false
    end

    clear_skinned_tracking_if_needed(menu_elements)

    local range = menu_elements.auto_skin_range and menu_elements.auto_skin_range:get() or 5
    local all_objects = get_cached_objects()
    local skinnable_corpses = {}

    for _, obj in __object_safety.live_ipairs(all_objects) do
        if not obj or not obj:is_valid() then
            goto continue
        end

        if not obj:is_unit() then
            goto continue
        end

        if not obj:is_dead() then
            goto continue
        end

        -- Check if corpse can be skinned
        local ok_skin, can_skin = pcall(function()
            return obj:can_be_skinned()
        end)
        if not ok_skin or not can_skin then
            goto continue
        end

        -- Check if already skinned (deduplication)
        if has_been_skinned(obj) then
            goto continue
        end

        local obj_pos = obj:get_position()
        if not obj_pos then
            goto continue
        end

        local dist = obj_pos:dist_to_ignore_z(player_pos)
        if dist > range then
            goto continue
        end

        table.insert(skinnable_corpses, { corpse = obj, distance = dist })

        ::continue::
    end

    -- Sort by distance (closest first)
    table.sort(skinnable_corpses, function(a, b)
        return a.distance < b.distance
    end)

    -- Attempt to skin the closest corpse
    for _, corpse_data in ipairs(skinnable_corpses) do
        local obj = corpse_data.corpse

        local ok_skin = pcall(function()
            core.input.skin_object(obj)
        end)

        if ok_skin then
            mark_as_skinned(obj)
            last_skin_time = now
            return true
        end
    end

    return false
end

---Optional menu rendering helper
---@param menu_elements table
function auto_skinning:on_menu_render(menu_elements)
    if not menu_elements then
        return
    end

    if menu_elements.auto_skin_enabled then
        menu_elements.auto_skin_enabled:render("Enable Auto Skinning")
    end

    if menu_elements.auto_skin_enabled and menu_elements.auto_skin_enabled:get_state() then
        if menu_elements.auto_skin_range then
            menu_elements.auto_skin_range:render("Skinning Range (yards)")
        end
    end
end

return auto_skinning
