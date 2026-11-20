local __object_safety=require("shared/object_safety")
local automation = {}

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type auto_loot
local auto_loot = require("shared/auto_loot")

---@type auto_mining
local auto_mining = require("shared/auto_mining")

---@type auto_quest_interact
local auto_quest_interact = require("shared/auto_quest_interact")

---@type auto_skinning
local auto_skinning = require("shared/auto_skinning")

-- questie_tracker now managed by shared/auto_quest_interact.lua module
-- ---@type questie_tracker|nil
-- local questie_tracker = nil
-- do
--     local ok_questie, questie_module = pcall(require, "common/utility/questie_tracker")
--     if ok_questie then
--         questie_tracker = questie_module
--     end
-- end

local spell_data = require("rotations/rogue/tbc/spell_data")

-- Ore IDs now managed by shared/auto_mining.lua module
-- local ore_ids =
-- {
--     [1731] = true,
--     [1732] = true,
--     [1733] = true,
--     [1735] = true,
--     [1734] = true,
--     [2040] = true,
--     [2047] = true,
--     [165658] = true,
--     [324] = true,
--     [175404] = true
-- }

-- Auto-loot state now managed by shared/auto_loot.lua module
-- local loot_attempts = {}

-- Pickpocket tracking (new multi-table system)
local pickpocketed_success = {}   -- Success tracking (persistent 3 min)
local pickpocket_pending = {}     -- Pending detection (waiting for loot window)
local pickpocket_lockouts = {}    -- Temporary lockouts for failed attempts

local last_pickpocket_cast_request_time = 0.0
local pickpocket_legit_cast_time_by_key = {}
local pickpocket_attempt_count_by_key = {}
local pickpocket_legit_callback_registered = false
local pickpocket_last_legit_any_time = 0.0

-- Pickpocket configuration
local pickpocket_config = {
    fail_behavior = 1,           -- 1=retry, 2=permanent, 3=temp_lockout
    temp_lockout_duration = 30,  -- Seconds
    cleanup_interval = 180,      -- 3 minutes
    detection_window = 1.5,      -- Wait time for loot window check (increased for latency)
    max_retries = 1              -- Max attempts before fallback success
}

local last_cleanup_time = 0.0
-- Mining and quest interact state now managed by shared modules
-- local last_mine_time = 0.0
-- local last_quest_interact_time = 0.0
-- local last_quest_interact_object_id = nil
-- Auto-loot window state now managed by shared/auto_loot.lua module
-- local last_loot_window_attempt_time = 0.0
-- local last_loot_window_count = 0
-- local loot_window_stagnant_attempts = 0
-- local loot_window_blocked_until = 0.0
-- local loot_window_auto_intent_until = 0.0
-- local loot_window_is_auto = false
-- local current_auto_loot_corpse_id = nil
-- local current_auto_loot_session_end = 0.0

local object_cache = {
    objects = {},
    last_update = 0.0,
    refresh_interval = 0.5
}

local function get_menu_elements(helpers)
    return helpers._menu_elements
end

local function get_cached_objects()
    local now = core.time()
    if (now - object_cache.last_update) >= object_cache.refresh_interval then
        object_cache.objects = core.object_manager.get_all_objects()
        object_cache.last_update = now
    end
    return object_cache.objects
end

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
---@return any|nil
local function safe_guid_key(obj)
    if not safe_is_valid(obj) then
        return nil
    end

    local ok_guid, guid = pcall(function()
        return obj:get_guid()
    end)
    if ok_guid and guid then
        local ok_str, guid_str = pcall(function()
            return tostring(guid)
        end)
        if ok_str and guid_str then
            return guid_str
        end
    end

    return nil
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

---@param obj game_object
---@return any|nil
local function safe_pickpocket_key(obj)
    local guid = safe_guid_key(obj)
    if guid then
        return guid
    end

    return safe_object_id(obj)
end

---@param key any
---@param locked_until number
local function upsert_pickpocket_lockout(key, locked_until)
    for i = #pickpocket_lockouts, 1, -1 do
        local entry = pickpocket_lockouts[i]
        if entry and entry.key == key then
            if not entry.locked_until or locked_until > entry.locked_until then
                entry.locked_until = locked_until
            end
            return
        end
    end

    table.insert(pickpocket_lockouts, {
        key = key,
        locked_until = locked_until
    })
end

-- local MAX_LOOT_ATTEMPTS_SIZE = 500
local MAX_PICKPOCKET_TARGETS_SIZE = 500

local function clear_tracking_if_needed(menu_elements)
    local now = core.time()

    -- Use pickpocket config cleanup interval (default: 180s)
    local interval = pickpocket_config.cleanup_interval

    local force_cleanup =
        #pickpocketed_success > MAX_PICKPOCKET_TARGETS_SIZE or
        #pickpocket_pending > MAX_PICKPOCKET_TARGETS_SIZE or
        #pickpocket_lockouts > MAX_PICKPOCKET_TARGETS_SIZE
        -- loot_attempts now managed by shared/auto_loot.lua
        -- or #loot_attempts > MAX_LOOT_ATTEMPTS_SIZE

    if not force_cleanup and (now - last_cleanup_time) < interval then
        return
    end

    last_cleanup_time = now

    -- Clean success list (persistent 3 min)
    for i = #pickpocketed_success, 1, -1 do
        local entry = pickpocketed_success[i]
        if not entry or not entry.time or not entry.key then
            table.remove(pickpocketed_success, i)
        elseif (now - entry.time) > interval then
            table.remove(pickpocketed_success, i)
        end
    end

    -- Clean stale pending (older than 5s = something went wrong)
    for i = #pickpocket_pending, 1, -1 do
        local entry = pickpocket_pending[i]
        if not entry or not entry.key or (entry.cast_time and (now - entry.cast_time) > 5) then
            table.remove(pickpocket_pending, i)
        end
    end

    -- Clean expired lockouts
    for i = #pickpocket_lockouts, 1, -1 do
        local entry = pickpocket_lockouts[i]
        if not entry or not entry.key or (entry.locked_until and now >= entry.locked_until) then
            table.remove(pickpocket_lockouts, i)
        end
    end

    -- Clean stale pickpocket attempt state
    for key, t in pairs(pickpocket_legit_cast_time_by_key) do
        if not t or (now - t) > interval then
            pickpocket_legit_cast_time_by_key[key] = nil
        end
    end
    for key, c in pairs(pickpocket_attempt_count_by_key) do
        if not c or c <= 0 or not pickpocket_legit_cast_time_by_key[key] then
            pickpocket_attempt_count_by_key[key] = nil
        end
    end

    -- loot_attempts cleanup now managed by shared/auto_loot.lua
    -- for i = #loot_attempts, 1, -1 do
    --     local entry = loot_attempts[i]
    --     if not entry or not entry.id then
    --         table.remove(loot_attempts, i)
    --     elseif entry.time and entry.time > 0 and (now - entry.time) > interval then
    --         table.remove(loot_attempts, i)
    --     end
    -- end
end

-- Loot attempt tracking and loot window handling now managed by shared/auto_loot.lua
-- local function get_loot_attempt_entry(menu_elements, corpse) ... end
-- local function increment_loot_attempts(corpse, max_attempts, lockout_seconds) ... end
-- local function try_loot_open_window(menu_elements) ... end

-- ============================================================================
-- PICKPOCKET DETECTION LOGIC
-- ============================================================================

---@param key any
---@param now number
local function handle_pickpocket_failure_by_key(key, now)
    local behavior = pickpocket_config.fail_behavior
    if not key then
        return
    end

    if behavior == 2 then
        table.insert(pickpocketed_success, { key = key, time = now })
    elseif behavior == 3 then
        upsert_pickpocket_lockout(key, now + pickpocket_config.temp_lockout_duration)
    end
end

---@param target game_object
---@param now number
local function handle_pickpocket_failure(target, now)
    local behavior = pickpocket_config.fail_behavior
    local key = safe_pickpocket_key(target)
    if not key then
        return
    end

    if behavior == 2 then
        -- Permanent: Mark as "done" (never retry)
        table.insert(pickpocketed_success, {
            key = key,
            time = now
        })
    elseif behavior == 3 then
        -- Temporary lockout
        upsert_pickpocket_lockout(key, now + pickpocket_config.temp_lockout_duration)
    end
    -- else: behavior == 1 (retry) → do nothing, target not tracked
end

---@param local_player game_object
local function check_pickpocket_pending(local_player)
    if #pickpocket_pending == 0 then
        return  -- Early exit optimization
    end

    local now = core.time()

    -- Check if loot window is open (indicates success)
    local ok_loot, loot_count = pcall(function()
        return core.game_ui.get_loot_item_count()
    end)

    local loot_window_open = ok_loot and loot_count and loot_count > 0

    -- Check combat state (indicates failure)
    local ok_combat, in_combat = pcall(function()
        return local_player:is_in_combat() or local_player:affecting_combat()
    end)
    local in_combat_now = ok_combat and in_combat

    -- Process all pending entries
    for i = #pickpocket_pending, 1, -1 do
        local entry = pickpocket_pending[i]
        if entry and not entry.key and entry.target then
            entry.key = safe_pickpocket_key(entry.target)
        end
        if not entry or not entry.key then
            table.remove(pickpocket_pending, i)
            goto continue
        end

        -- SUCCESS Path 1: Loot window opened (loot_count > 0)
        if loot_window_open then
            table.insert(pickpocketed_success, {
                key = entry.key,
                time = now
            })
            pickpocket_attempt_count_by_key[entry.key] = nil
            table.remove(pickpocket_pending, i)

        -- FAILURE: Entered combat (resist/aggro)
        elseif in_combat_now then
            handle_pickpocket_failure_by_key(entry.key, now)
            pickpocket_attempt_count_by_key[entry.key] = nil
            table.remove(pickpocket_pending, i)

        -- TIMEOUT: Check retry count
        elseif now >= entry.timeout then
            local legit_time = pickpocket_legit_cast_time_by_key[entry.key]
            local has_legit_attempt = legit_time and entry.cast_time and legit_time >= (entry.cast_time - 0.25)
            if not has_legit_attempt and pickpocket_last_legit_any_time > 0 and entry.cast_time then
                has_legit_attempt = pickpocket_last_legit_any_time >= (entry.cast_time - 0.25)
            end

            if not has_legit_attempt then
                -- Nothing was actually cast (range/LOS/etc). Allow retry later without marking success.
                upsert_pickpocket_lockout(entry.key, now + 0.25)
                table.remove(pickpocket_pending, i)
                goto continue
            end

            if not entry.counted_legit then
                pickpocket_attempt_count_by_key[entry.key] = (pickpocket_attempt_count_by_key[entry.key] or 0) + 1
                entry.counted_legit = true
            end

            local attempt_count = pickpocket_attempt_count_by_key[entry.key] or 0
            if attempt_count >= pickpocket_config.max_retries then
                -- Fallback after max retries (assumed empty loot)
                table.insert(pickpocketed_success, { key = entry.key, time = now })
                pickpocket_attempt_count_by_key[entry.key] = nil
                table.remove(pickpocket_pending, i)
            else
                -- Schedule a retry without spamming
                upsert_pickpocket_lockout(entry.key, now + 0.25)
                table.remove(pickpocket_pending, i)
            end
        end
        -- else: still waiting, keep in pending

        ::continue::
    end
end

function automation.register(helpers)
    local log_throttled = helpers._log_throttled
    local get_spell_diag_id = helpers._get_spell_diag_id
    local get_object_diag_id = helpers._get_object_diag_id

    if not pickpocket_legit_callback_registered then
        pickpocket_legit_callback_registered = true
        pcall(function()
            core.register_on_legit_spell_cast_callback(__object_safety.callback(function(data)
                local pp = spell_data and spell_data.utility and spell_data.utility.pick_pocket
                local pickpocket_spell_id = pp and pp.ids and pp.ids[1] or 921

                local spell_id = nil
                local target = nil

                if type(data) == "table" then
                    spell_id = data.spell_id
                    target = data.target
                else
                    spell_id = data
                end

                if not spell_id or spell_id ~= pickpocket_spell_id then
                    return
                end

                local now = core.time()
                pickpocket_last_legit_any_time = now

                -- If the callback doesn't provide a target (some builds pass only the spell_id),
                -- attribute the attempt to the current pending target (only one is allowed).
                if not target then
                    local pending = pickpocket_pending[1]
                    target = pending and pending.target_ref or nil
                end

                local key = safe_pickpocket_key(target)
                if not key then
                    return
                end

                -- Avoid counting attempts when we are clearly not in a valid pickpocket position.
                local local_player = core.object_manager.get_local_player()
                if not safe_is_valid(local_player) then
                    return
                end
                local ok_moving, is_moving = pcall(function()
                    return local_player:is_moving()
                end)
                if ok_moving and is_moving then
                    return
                end
                local ok_p, player_pos = pcall(function() return local_player:get_position() end)
                local ok_t, target_pos = pcall(function() return target:get_position() end)
                if not (ok_p and player_pos and ok_t and target_pos) then
                    return
                end
                if target_pos:dist_to_ignore_z(player_pos) > 4.0 then
                    return
                end
                local ok_behind, behind = pcall(function() return local_player:is_behind(target) end)
                if ok_behind and behind == false then
                    return
                end
                local ok_range, in_range = pcall(function() return target:is_spell_in_range(pickpocket_spell_id) end)
                if ok_range and in_range == false then
                    return
                end

                pickpocket_legit_cast_time_by_key[key] = now
                pickpocket_attempt_count_by_key[key] = (pickpocket_attempt_count_by_key[key] or 0) + 1

                for i = 1, #pickpocket_pending do
                    local entry = pickpocket_pending[i]
                    if entry and entry.key == key then
                        entry.cast_time = now
                        entry.timeout = now + pickpocket_config.detection_window
                        entry.attempt_count = pickpocket_attempt_count_by_key[key]
                        entry.counted_legit = true
                        break
                    end
                end
            end,"rotations/rogue/tbc/helpers/automation.lua:417"))
        end)
    end

    -- ============================================================================
    -- PICKPOCKET CONFIG SYNC & DETECTION (PUBLIC METHODS)
    -- ============================================================================

    ---@param self helpers
    function helpers:sync_pickpocket_config()
        local menu = self._menu_elements
        if not menu then return end

        if menu.pickpocket_fail_behavior then
            pickpocket_config.fail_behavior = menu.pickpocket_fail_behavior:get()
        end
        if menu.pickpocket_temp_lockout then
            pickpocket_config.temp_lockout_duration = menu.pickpocket_temp_lockout:get()
        end
        if menu.pickpocket_cleanup_interval then
            pickpocket_config.cleanup_interval = menu.pickpocket_cleanup_interval:get()
        end
        if menu.pickpocket_max_retries then
            pickpocket_config.max_retries = menu.pickpocket_max_retries:get()
        end
    end

    ---@param self helpers
    ---@param local_player game_object
    function helpers:check_pickpocket_detection(local_player)
        check_pickpocket_pending(local_player)
    end

    -- ============================================================================
    -- PICKPOCKET TRACKING
    -- ============================================================================

    ---@param target game_object
    ---@return boolean
    function helpers:has_been_pickpocketed(target)
        if not safe_is_valid(target) then
            return false
        end

        local now = core.time()
        local key = safe_pickpocket_key(target)
        if not key then
            return false
        end

        -- Check if already pending (don't retry during detection)
        for _, entry in ipairs(pickpocket_pending) do
            if entry and entry.key == key then
                return true
            end
        end

        -- Check success list
        for _, entry in ipairs(pickpocketed_success) do
            if entry and entry.key == key then
                return true
            end
        end

        -- Check temporary lockouts
        for i = #pickpocket_lockouts, 1, -1 do
            local entry = pickpocket_lockouts[i]
            if entry and entry.key == key then
                if now < entry.locked_until then
                    return true  -- Still locked
                else
                    table.remove(pickpocket_lockouts, i)  -- Expired
                    return false
                end
            end
        end

        return false
    end

    -- ============================================================================
    -- AUTO PICKPOCKET EXECUTION
    -- ============================================================================

    ---@param local_player game_object
    ---@return boolean
    function helpers:try_pickpocket(local_player)
        if not local_player then
            return false
        end

        if local_player:is_mounted() then
            return false
        end

        local menu_elements = get_menu_elements(helpers)
        if not self:is_pickpocket_toggle_active() then
            return false
        end

        clear_tracking_if_needed(menu_elements)

        -- ✅ CRITICAL FIX: Only allow ONE pending pickpocket at a time
        -- Prevents race conditions where multiple targets share the same loot window
        if #pickpocket_pending > 0 then
            return false  -- Already waiting for detection on another target
        end

        if not self:has_buff(local_player, "stealth") then
            return false
        end

        local ok_moving, is_moving = pcall(function()
            return local_player:is_moving()
        end)
        if ok_moving and is_moving then
            return false
        end

        local now = core.time()
        if (now - last_pickpocket_cast_request_time) < 0.25 then
            return false
        end

        local player_pos = local_player:get_position()
        if not player_pos then
            return false
        end

        local valid_targets = {}
        local all_objects = get_cached_objects()

        for _, target in __object_safety.live_ipairs(all_objects) do
            if not target or not target:is_valid() then
                goto continue
            end

            if not target:is_unit() then
                goto continue
            end

            local ok_player, is_player = pcall(function()
                return target:is_player()
            end)
            if ok_player and is_player then
                goto continue
            end

            if target:is_dead() then
                goto continue
            end

            local target_pos = target:get_position()
            if not target_pos then
                goto continue
            end

            local dist = target_pos:dist_to_ignore_z(player_pos)
            if dist > 4.0 then
                goto continue
            end

            local ok_friend, is_friend = pcall(function()
                return target:is_friend_with(local_player)
            end)
            if ok_friend and is_friend then
                goto continue
            end

            local ok_can_attack, can_attack = pcall(function()
                return local_player:can_attack(target)
            end)
            if ok_can_attack and not can_attack then
                goto continue
            end

            if self:has_been_pickpocketed(target) then
                goto continue
            end

            local creature_type = target:get_creature_type()
            if creature_type ~= 7 then
                goto continue
            end

            local ok_behind, behind = pcall(function()
                return local_player:is_behind(target)
            end)
            if ok_behind and behind == false then
                goto continue
            end

            table.insert(valid_targets, {target = target, distance = dist})

            ::continue::
        end

        table.sort(valid_targets, function(a, b)
            return a.distance < b.distance
        end)

        for _, target_data in ipairs(valid_targets) do
            local target = target_data.target

            local pp = spell_data.utility.pick_pocket
            local spell_id = pp.ids[1]

            local is_castable = spell_helper:is_spell_castable(
                spell_id,
                local_player,
                target,
                false,
                false,
                false,
                false,
                false
            )

            if is_castable then
                local diag_enabled = menu_elements and menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
                local diag_id = get_spell_diag_id("pick_pocket")
                if diag_enabled then
                    log_throttled("spell.try." .. diag_id, 1.0, "[SPELL] TRY " .. diag_id)
                end

                spell_queue:queue_spell_target(spell_id, target, 5, pp.name)
                if diag_enabled then
                    log_throttled("spell.ok." .. diag_id, 1.0, "[SPELL] QUEUED " .. diag_id)
                end
                do
                    local now = core.time()
                    last_pickpocket_cast_request_time = now

                    -- ✅ CRITICAL FIX: Set auto-loot intent flag so window gets processed
                    auto_loot:set_auto_intent(1.5)

                    -- ✅ Store target OBJECT not ID string (solves position-based ID bugs)
                    local key = safe_pickpocket_key(target)
                    if key then
                        table.insert(pickpocket_pending, {
                            key = key,
                            target_ref = target,
                            cast_time = now,
                            timeout = now + pickpocket_config.detection_window,
                            attempt_count = pickpocket_attempt_count_by_key[key] or 0,
                            counted_legit = false
                        })
                    end

                    return true
                end
            end
        end

        return false
    end

    -- ============================================================================
    -- AUTO QUEST INTERACT (OPEN WORLD)
    -- ============================================================================

    -- ============================================================================
    -- AUTO QUEST INTERACT (Delegated to shared/auto_quest_interact.lua)
    -- ============================================================================

    ---@param local_player game_object
    ---@return boolean
    function helpers:try_auto_interact_quest_objects(local_player)
        local menu_elements = get_menu_elements(helpers)
        return auto_quest_interact:on_update(local_player, menu_elements)
    end

    -- ============================================================================
    -- AUTO MINING (Delegated to shared/auto_mining.lua)
    -- ============================================================================

    ---@param local_player game_object
    ---@return boolean
    function helpers:try_auto_mine(local_player)
        local menu_elements = get_menu_elements(helpers)
        return auto_mining:on_update(local_player, menu_elements)
    end

    -- ============================================================================
    -- AUTO SKINNING (Delegated to shared/auto_skinning.lua)
    -- ============================================================================

    ---@param local_player game_object
    ---@return boolean
    function helpers:try_auto_skin(local_player)
        local menu_elements = get_menu_elements(helpers)
        return auto_skinning:on_update(local_player, menu_elements)
    end

    -- ============================================================================
    -- AUTO LOOT SYSTEM (Delegated to shared/auto_loot.lua)
    -- ============================================================================

    ---@param local_player game_object
    ---@return boolean
    function helpers:try_auto_loot(local_player)
        local menu_elements = get_menu_elements(helpers)
        return auto_loot:on_update(local_player, menu_elements)
    end
end

return automation
