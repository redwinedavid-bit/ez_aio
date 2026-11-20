local __object_safety=require("shared/object_safety")
-- Auto Loot Module (Shared)
-- Provides automatic looting functionality for all rotations

local auto_loot = {}

-- ============================================================================
-- MODULE IMPORTS
-- ============================================================================

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

local loot_attempts = {}
local loot_window_auto_intent_until = 0.0
local loot_window_is_auto = false
local loot_window_blocked_until = 0.0
local last_loot_window_attempt_time = 0.0
local last_loot_window_count = 0
local loot_window_stagnant_attempts = 0

local object_cache = {
    objects = {},
    last_update = 0.0,
    refresh_interval = 0.5
}

local MAX_LOOT_ATTEMPTS_SIZE = 500

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
local function clear_tracking_if_needed(menu_elements)
    local now = core.time()

    -- Cleanup interval is automatically 2x the corpse lockout time
    local corpse_lockout = 60  -- default
    if menu_elements and menu_elements.auto_loot_retry_delay then
        corpse_lockout = menu_elements.auto_loot_retry_delay:get() or 60
    end
    local cleanup_interval = corpse_lockout * 2

    local force_cleanup = #loot_attempts > MAX_LOOT_ATTEMPTS_SIZE

    if not force_cleanup and (now - (object_cache.last_cleanup or 0.0)) < cleanup_interval then
        return
    end

    object_cache.last_cleanup = now

    -- Clean loot attempts
    for i = #loot_attempts, 1, -1 do
        local entry = loot_attempts[i]
        if not entry or not entry.id then
            table.remove(loot_attempts, i)
        elseif entry.time and entry.time > 0 and (now - entry.time) > cleanup_interval then
            table.remove(loot_attempts, i)
        end
    end
end

---@param corpse game_object
---@return table|nil
local function get_loot_attempt_entry(menu_elements, corpse)
    local corpse_id = safe_object_id(corpse)

    if not corpse_id then
        return nil
    end

    local now = core.time()

    -- Cleanup interval is automatically 2x the corpse lockout time
    local corpse_lockout = 60  -- default
    if menu_elements and menu_elements.auto_loot_retry_delay then
        corpse_lockout = menu_elements.auto_loot_retry_delay:get() or 60
    end
    local cleanup_interval = corpse_lockout * 2

    for i = #loot_attempts, 1, -1 do
        local entry = loot_attempts[i]
        if not entry or not entry.id then
            table.remove(loot_attempts, i)
        elseif cleanup_interval > 0 and entry.time and entry.time > 0 and (now - entry.time) > cleanup_interval then
            table.remove(loot_attempts, i)
        end
    end

    for i = 1, #loot_attempts do
        local entry = loot_attempts[i]
        if entry and entry.id == corpse_id then
            return entry
        end
    end

    return nil
end

---@param corpse game_object
---@param max_attempts integer
---@param lockout_seconds integer
local function increment_loot_attempts(corpse, max_attempts, lockout_seconds)
    local corpse_id = safe_object_id(corpse)

    if not corpse_id then
        return
    end

    local now = core.time()
    local locked_until = 0.0
    if max_attempts and max_attempts > 0 and lockout_seconds and lockout_seconds > 0 then
        locked_until = now + lockout_seconds
    end

    for i = 1, #loot_attempts do
        if loot_attempts[i].id == corpse_id then
            loot_attempts[i].count = loot_attempts[i].count + 1
            loot_attempts[i].time = now
            if loot_attempts[i].count >= max_attempts then
                loot_attempts[i].locked_until = locked_until
            end
            return
        end
    end

    local entry =
    {
        id = corpse_id,
        count = 1,
        time = now,
        locked_until = 0.0
    }

    if entry.count >= max_attempts then
        entry.locked_until = locked_until
    end

    table.insert(loot_attempts, entry)
end

---@return boolean
local function try_loot_open_window(menu_elements)
    local ok_count, loot_count = pcall(function()
        return core.game_ui.get_loot_item_count()
    end)

    if not ok_count or not loot_count or loot_count <= 0 then
        last_loot_window_attempt_time = 0.0
        last_loot_window_count = 0
        loot_window_stagnant_attempts = 0
        loot_window_blocked_until = 0.0
        loot_window_is_auto = false
        return false
    end

    local now = core.time()
    if now < loot_window_blocked_until then
        return false
    end

    -- Check if this window was opened by the bot during an active auto-loot session
    if not loot_window_is_auto then
        if now <= loot_window_auto_intent_until then
            -- Window opened shortly after bot loot call, mark as auto
            loot_window_is_auto = true
        else
            -- Manual open OR outside active session → DO NOT auto-close
            return false
        end
    end

    local max_attempts = menu_elements and menu_elements.auto_loot_max_attempts and menu_elements.auto_loot_max_attempts:get() or 3

    local prev_count = last_loot_window_count
    if loot_count == prev_count then
        loot_window_stagnant_attempts = loot_window_stagnant_attempts + 1
    else
        loot_window_stagnant_attempts = 0
    end

    -- Loot all items (bottom-up)
    local ok_loot = true
    for i = loot_count, 1, -1 do
        local ok_item = pcall(function()
            core.input.loot_item(i)
        end)
        if not ok_item then
            ok_loot = false
        end
    end

    last_loot_window_attempt_time = now
    last_loot_window_count = loot_count

    -- Auto-close ONLY if:
    -- 1. Window is flagged as auto (opened by bot)
    -- 2. Items haven't changed (stagnant)
    -- 3. Stagnant for max_attempts frames
    if loot_window_stagnant_attempts >= max_attempts and loot_count == prev_count then
        pcall(function()
            core.input.close_loot()
        end)
        loot_window_blocked_until = now + 1.5  -- Short 1.5s block between auto-close cycles
        loot_window_stagnant_attempts = 0
        loot_window_auto_intent_until = 0.0
        loot_window_is_auto = false
    end

    return ok_loot
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

---Set auto-loot intent flag (for pickpocket or other features)
---@param duration number|nil
function auto_loot:set_auto_intent(duration)
    loot_window_auto_intent_until = core.time() + (duration or 1.5)
end

---Main auto-loot function
---@param local_player game_object
---@param menu_elements table
---@return boolean
function auto_loot:on_update(local_player, menu_elements)
    if not local_player then
        return false
    end

    if local_player:is_mounted() then
        return false
    end

    if not menu_elements or not menu_elements.auto_loot_enabled then
        return false
    end

    if not menu_elements.auto_loot_enabled:get_state() then
        return false
    end

    if local_player:is_moving() then
        return false
    end

    local loot_mode = menu_elements.auto_loot_mode and menu_elements.auto_loot_mode:get() or 1
    local in_combat = unit_helper:is_in_combat(local_player)

    if loot_mode == 1 and in_combat then
        return false
    elseif loot_mode == 2 and not in_combat then
        return false
    end

    if try_loot_open_window(menu_elements) then
        return true
    end

    local max_attempts = menu_elements.auto_loot_max_attempts and menu_elements.auto_loot_max_attempts:get() or 3
    local lockout_seconds = menu_elements.auto_loot_retry_delay and menu_elements.auto_loot_retry_delay:get() or 5

    local player_pos = local_player:get_position()
    if not player_pos then
        return false
    end

    clear_tracking_if_needed(menu_elements)

    local all_objects = get_cached_objects()
    local lootable_corpses = {}

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

        local ok_loot, can_loot = pcall(function()
            return obj:can_be_looted()
        end)
        if not ok_loot or not can_loot then
            goto continue
        end

        local obj_pos = obj:get_position()
        if not obj_pos then
            goto continue
        end

        local dist = obj_pos:dist_to_ignore_z(player_pos)
        if dist > 5 then
            goto continue
        end

        table.insert(lootable_corpses, { corpse = obj, distance = dist })

        ::continue::
    end

    table.sort(lootable_corpses, function(a, b)
        return a.distance < b.distance
    end)

    local now = core.time()
    for _, corpse_data in ipairs(lootable_corpses) do
        local obj = corpse_data.corpse

        local entry = get_loot_attempt_entry(menu_elements, obj)
        local attempts = entry and entry.count or 0

        -- Check if this corpse is locked out
        if entry and entry.locked_until and entry.locked_until > 0 then
            if now < entry.locked_until then
                -- Still locked out, skip this corpse
                goto continue_loot
            end

            -- Lockout expired, reset for new cycle
            entry.locked_until = 0.0
            entry.count = 0
            attempts = 0
        end

        -- If already at max attempts (shouldn't happen if lockout works correctly), skip
        if attempts >= max_attempts then
            goto continue_loot
        end

        -- Attempt to loot (attempts is 0, 1, or 2 at this point)
        loot_window_auto_intent_until = core.time() + 1.5
        local ok_loot = pcall(function()
            core.input.loot_object(obj)
        end)

        if ok_loot then
            increment_loot_attempts(obj, max_attempts, lockout_seconds)

            -- If this was the final attempt (now at max), apply lockout immediately
            local updated_entry = get_loot_attempt_entry(menu_elements, obj)
            if updated_entry and updated_entry.count >= max_attempts then
                updated_entry.locked_until = now + lockout_seconds
            end

            return true
        end

        ::continue_loot::
    end

    return false
end

---Optional menu rendering helper
---@param menu_elements table
function auto_loot:on_menu_render(menu_elements)
    if not menu_elements then
        return
    end

    if menu_elements.auto_loot_enabled then
        menu_elements.auto_loot_enabled:render("Enable Auto Loot")
    end

    if menu_elements.auto_loot_enabled and menu_elements.auto_loot_enabled:get_state() then
        if menu_elements.auto_loot_mode then
            menu_elements.auto_loot_mode:render("Loot Mode", {
                "Out of Combat Only",
                "In Combat Only",
                "Always"
            })
        end

        if menu_elements.auto_loot_max_attempts then
            menu_elements.auto_loot_max_attempts:render("Max Attempts per Corpse")
        end

        if menu_elements.auto_loot_retry_delay then
            menu_elements.auto_loot_retry_delay:render("Corpse Lockout (seconds)")
        end
    end
end

return auto_loot
