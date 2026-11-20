local __object_safety=require("shared/object_safety")
-- Helper functions for BxA Rotation
-- Provides weapon detection, position checks, buff management, and spell casting wrappers

local helpers = {}

-- ============================================================================
-- MODULE IMPORTS
-- ============================================================================

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type pvp_helper
local pvp_utiltiy = require("common/utility/pvp_helper")

---@type auto_skinning
local auto_skinning = require("shared/auto_skinning")

---@type questie_tracker|nil
local questie_tracker = nil
do
    local ok_questie, questie_module = pcall(require, "common/utility/questie_tracker")
    if ok_questie then
        questie_tracker = questie_module
    end
end

---@type enums
local enums = require("common/enums")

---@type simple_movement
local movement = require("common/utility/simple_movement")

---@type izi_api
local izi = require("common/izi_sdk")

local spell_data = require("rotations/rogue/tbc/spell_data")
local resource_ticks = require("shared/resource_ticks")
local ar_timing = require("shared/rogue_adrenaline_rush_timing")
local rotation_pause = require("shared/rotation_pause")

--- Safe wrapper for retrieving the local player object.
--- Prevents nil-index crashes in higher-level rotation logic.
---@return game_object|nil
function helpers:get_player()
    local ok, player = pcall(function() return core.get_local_player() end)
    if ok and player and player:is_valid() then
        return player
    end
    return nil
end


-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

local menu_elements = nil
local last_cast_time = {}
local last_engineering_use_time = 0.0
local last_target_dummy_use_time = 0.0
local last_vanish_time = 0.0
local last_mine_time = 0.0
local last_quest_interact_time = 0.0
local last_quest_interact_object_id = nil
local last_loot_window_attempt_time = 0.0
local last_loot_window_count = 0
local loot_window_stagnant_attempts = 0
local loot_window_blocked_until = 0.0
local loot_window_auto_intent_until = 0.0
local loot_window_is_auto = false
local pending_kick_pct = 0.0
local pending_kick_target_guid = nil
local pending_gouge_pct = 0.0
local pending_gouge_target_guid = nil
local pending_nearby_kick_pct = 0.0
local pending_nearby_kick_target_guid = nil
local KICK_DELAY_MIN_PCT = 10
local KICK_DELAY_MAX_PCT = 35
local cached_stoneform_bleed_ids = nil
local last_cloak_check_time = 0.0

---@return boolean
local function get_menu_int(menu_el, fallback)
    if not menu_el or not menu_el.get then
        return fallback
    end
    local v = menu_el:get()
    if type(v) ~= "number" then
        return fallback
    end
    return v
end

local function get_menu_combo(menu_el, fallback)
    if not menu_el or not menu_el.get then
        return fallback
    end
    local v = menu_el:get()
    if type(v) ~= "number" then
        return fallback
    end
    return v
end

---@param unit game_object|nil
---@return number
local function safe_get_gcd_remains_ms(unit)
    if not unit then
        return 0
    end
    local ok, v = pcall(function()
        return unit:gcd_remains()
    end)
    if not ok or type(v) ~= "number" or v <= 0 then
        return 0
    end
    return math.floor((v * 1000) + 0.5)
end

local spell_diag_ids = {}
local next_spell_diag_id = 1

---@param spell_key string
---@return string
local function get_spell_diag_id(spell_key)
    if not spell_key then
        return "0"
    end

    local existing = spell_diag_ids[spell_key]
    if existing then
        return existing
    end

    local id = tostring(next_spell_diag_id)
    next_spell_diag_id = next_spell_diag_id + 1
    spell_diag_ids[spell_key] = id
    return id
end

local item_diag_ids = {}
local next_item_diag_id = 1

---@param item_key string
---@return string
local function get_item_diag_id(item_key)
    if not item_key then
        return "0"
    end

    local existing = item_diag_ids[item_key]
    if existing then
        return existing
    end

    local id = tostring(next_item_diag_id)
    next_item_diag_id = next_item_diag_id + 1
    item_diag_ids[item_key] = id
    return id
end

local object_diag_ids = {}
local next_object_diag_id = 1

---@param object_key string
---@return string
local function get_object_diag_id(object_key)
    if not object_key then
        return "0"
    end

    local existing = object_diag_ids[object_key]
    if existing then
        return existing
    end

    local id = tostring(next_object_diag_id)
    next_object_diag_id = next_object_diag_id + 1
    object_diag_ids[object_key] = id
    return id
end

---@return number[] bleed_ids
local function get_stoneform_bleed_ids()
    if cached_stoneform_bleed_ids then
        return cached_stoneform_bleed_ids
    end

    local bleed_ids = {}
    local seen = {}

    if spell_data and spell_data.damage_over_time then
        local bleed_groups = {
            spell_data.damage_over_time.rogue_bleeds,
            spell_data.damage_over_time.warrior_bleeds,
            spell_data.damage_over_time.druid_bleeds
        }

        for _, group in ipairs(bleed_groups) do
            if type(group) == "table" then
                for _, id in ipairs(group) do
                    if id and not seen[id] then
                        seen[id] = true
                        table.insert(bleed_ids, id)
                    end
                end
            end
        end
    end

    cached_stoneform_bleed_ids = bleed_ids
    return cached_stoneform_bleed_ids
end

---@param menu table
---@return number min_pct, number max_pct
local function get_kick_delay_pct_range(menu)
    if not menu or not menu.kick_delay_min_pct or not menu.kick_delay_max_pct then
        return KICK_DELAY_MIN_PCT, KICK_DELAY_MAX_PCT
    end

    local min_pct = menu.kick_delay_min_pct:get() or KICK_DELAY_MIN_PCT
    local max_pct = menu.kick_delay_max_pct:get() or KICK_DELAY_MAX_PCT

    if min_pct < 0 then
        min_pct = 0
    end
    if max_pct > 100 then
        max_pct = 100
    end
    if max_pct < min_pct then
        max_pct = min_pct
    end

    return min_pct, max_pct
end

-- ============================================================================
-- DEBUG HELPER
-- ============================================================================

local helpers_log_last_times = {}

---@param log_key string
---@param interval number
---@param message string
---@return boolean did_log
local function log_throttled(log_key, interval, message)
    if not menu_elements or not menu_elements.rotation_log_enabled or not menu_elements.rotation_log_enabled:get_state() then
        return false
    end

    local now = core.time()
    local last_time = helpers_log_last_times[log_key] or 0.0
    if (now - last_time) < interval then
        return false
    end

    core.log(message)
    helpers_log_last_times[log_key] = now
    return true
end

---@param log_key string
---@param interval number|nil
---@param message string
---@return boolean did_log
function helpers:log_throttled(log_key, interval, message)
    return log_throttled(log_key, interval or 2.0, message)
end

---@param checkpoint_key string
---@param interval number|nil
---@param message string
---@return boolean did_log
function helpers:log_checkpoint(checkpoint_key, interval, message)
    return log_throttled("cp." .. tostring(checkpoint_key), interval or 1.0, message)
end

helpers._get_spell_diag_id = get_spell_diag_id
helpers._get_item_diag_id = get_item_diag_id
helpers._get_object_diag_id = get_object_diag_id

helpers._log_throttled = log_throttled

---@param log_key string
---@param message string
local function debug_print(log_key, message)
    if not menu_elements or not menu_elements.debug_mode_enabled or not menu_elements.debug_mode_enabled:get_state() then
        return
    end
    log_throttled("debug." .. log_key, 2.0, message)
end

local engineering_items =
{
    dynamite =
    {
        { name = "Rough Dynamite", item_id = 4358, can_stun = false },
        { name = "Coarse Dynamite", item_id = 4360, can_stun = false },
        { name = "Heavy Dynamite", item_id = 4365, can_stun = false },
        { name = "Solid Dynamite", item_id = 10507, can_stun = false },
        { name = "Dense Dynamite", item_id = 18641, can_stun = false },
        { name = "Goblin Fishing Pole", item_id = 4598, can_stun = false }
    },
    bombs =
    {
        { name = "Small Seaforium Charge", item_id = 4367, can_stun = false },
        { name = "Large Seaforium Charge", item_id = 4398, can_stun = false },
        { name = "Rough Copper Bomb", item_id = 4370, can_stun = true },
        { name = "Small Bronze Bomb", item_id = 4374, can_stun = true },
        { name = "Big Bronze Bomb", item_id = 4378, can_stun = true },
        { name = "Iron Grenade", item_id = 4390, can_stun = true },
        { name = "Big Iron Bomb", item_id = 4394, can_stun = true },
        { name = "Mithril Frag Bomb", item_id = 10514, can_stun = true },
        { name = "Hi-Explosive Bomb", item_id = 10562, can_stun = true },
        { name = "Thorium Grenade", item_id = 15993, can_stun = true },
        { name = "Dark Iron Bomb", item_id = 16005, can_stun = true },
        { name = "Arcane Bomb", item_id = 16040, can_stun = false }
    },
    sapper =
    {
        { name = "Goblin Sapper Charge", item_id = 10646, can_stun = false, self_damage = true }
    },
    special_explosives =
    {
        { name = "Ez-Thro Dynamite", item_id = 6714, can_stun = false },
        { name = "Ez-Thro Dynamite II", item_id = 6715, can_stun = false }
    }
}

local ore_ids =
{
    [1731] = true,
    [1732] = true,
    [1733] = true,
    [1735] = true,
    [1734] = true,
    [2040] = true,
    [2047] = true,
    [165658] = true,
    [324] = true,
    [175404] = true
}

---@param menu table
function helpers:set_menu_elements(menu)
    menu_elements = menu
    helpers._menu_elements = menu
end

---@param local_player game_object|nil
---@return number
function helpers:get_combo_points(local_player)
    if not local_player then
        return 0
    end

    -- TBC Combo Points: Check both raw power (Type 51) and client-side points
    local cp = 0
    local ok, v = pcall(function()
        -- Try modern client-side points first
        if local_player.combo_points_current then
            return local_player:combo_points_current()
        end
        -- Fallback to Power Type 4 (ERA) or 51 (TBC)
        local points = local_player:get_power(4)
        if points and points > 0 then return points end
        return local_player:get_power(51) -- TBC COMBO_POINTS
    end)

    if ok and type(v) == "number" and v >= 0 then
        cp = v
    end

    return cp
end

---@param local_player game_object
---@param item_id number
---@return boolean
local function has_item_in_inventory(local_player, item_id)
    if not local_player then
        return false
    end
    return local_player:has_item(item_id)
end

helpers._has_item_in_inventory = has_item_in_inventory

-- ============================================================================
-- WEAPON DETECTION
-- ============================================================================

---@param local_player game_object
---@return string weapon_type "dagger", "sword", "axe", "mace", "fist", "unknown"
function helpers:get_main_hand_weapon_type(local_player)
    -- WoW Classic Lua API is not allowed; weapon type detection is intentionally disabled.
    -- Spell weapon restrictions are validated via spell_helper:is_spell_castable.
    return "unknown"
end

---@param local_player game_object
---@return boolean
function helpers:has_dagger_equipped(local_player)
    return false
end

-- ============================================================================
-- POSITION CHECKS
-- ============================================================================

---@param local_player game_object
---@param target game_object
---@return boolean
function helpers:is_behind_target(local_player, target)
    if not local_player or not target then
        return false
    end

    local player_pos = local_player:get_position()
    local target_pos = target:get_position()
    local target_rotation = target:get_rotation()

    if not player_pos or not target_pos then
        return false
    end

    -- Calculate angle from target to player
    local dx = player_pos.x - target_pos.x
    local dy = player_pos.y - target_pos.y
    local angle_to_player = math.atan2(dy, dx)

    -- Normalize angle difference
    local angle_diff = math.abs(angle_to_player - target_rotation)
    if angle_diff > math.pi then
        angle_diff = 2 * math.pi - angle_diff
    end

    -- Behind = ±90° (Pi/2 Radians) from target facing
    -- More lenient for latency: use 60° threshold (Pi/3)
    return angle_diff > (math.pi / 3)
end

---@param local_player game_object
---@param target game_object
---@param half_angle_rad number|nil
---@return boolean
function helpers:is_in_front_arc(local_player, target, half_angle_rad)
    if not local_player or not target then
        return false
    end

    local player_pos = local_player:get_position()
    local target_pos = target:get_position()
    if not player_pos or not target_pos then
        return false
    end

    local facing = local_player:get_direction()
    if not facing then
        return false
    end

    local dx = target_pos.x - player_pos.x
    local dy = target_pos.y - player_pos.y
    local dist_sq = (dx * dx) + (dy * dy)
    if dist_sq <= 0.0001 then
        return true
    end

    local facing_len_sq = (facing.x * facing.x) + (facing.y * facing.y)
    if facing_len_sq <= 0.0001 then
        return false
    end

    local dot = (facing.x * dx) + (facing.y * dy)
    local cos_angle = dot / (math.sqrt(facing_len_sq) * math.sqrt(dist_sq))
    if cos_angle > 1 then
        cos_angle = 1
    elseif cos_angle < -1 then
        cos_angle = -1
    end

    local angle = math.acos(cos_angle)
    local half_angle = half_angle_rad or (math.pi / 2)
    return angle <= half_angle
end

local function meets_facing_requirement(local_player, target, requires_facing)
    if not local_player or not target then
        return false
    end

    if requires_facing == "behind" then
        return helpers:is_behind_target(local_player, target)
    end

    return helpers:is_in_front_arc(local_player, target, math.pi / 2)
end

-- ============================================================================
-- BUFF/DEBUFF MANAGEMENT
-- ============================================================================

---@param unit game_object
---@param buff_name string
---@return number remaining_ms
function helpers:get_buff_remaining(unit, buff_name)
    if not unit then
        return 0
    end

    local buff_ids = spell_data.buffs[buff_name]
    if not buff_ids then
        return 0
    end

    local buff_data = buff_manager:get_buff_data(unit, buff_ids)
    if buff_data and buff_data.is_active then
        return buff_data.remaining
    end

    return 0
end

---@param unit game_object
---@param buff_name string
---@return boolean
function helpers:has_buff(unit, buff_name)
    return self:get_buff_remaining(unit, buff_name) > 0
end

-- ============================================================================
-- SPELL CASTING (Priority Functions)
-- ============================================================================

-- ============================================================================
-- GENERIC SPELL CASTING WRAPPER
-- Eliminates duplication across try_cast_builder, try_cast_finisher, etc.
-- ============================================================================
-- THROTTLE TIMINGS: Builders 0.15s, CC 0.5s, Engineering 1.0s
-- QUEUE PRIORITIES: 10 (emergency) > 6 (eng) > 5 (pick) > 3 (cc) > 2 (fin) > 1 (build)
-- ============================================================================

--- Generic spell casting function that handles all spell types.
--- This wrapper consolidates the common pattern used by all try_cast_X functions:
--- 1. Throttle check (prevents spam casting)
--- 2. Spell data lookup
--- 3. Weapon/position/facing requirements
--- 4. Rank iteration (highest → lowest)
--- 5. spell_helper:is_spell_castable (Project Silvanas pattern)
--- 6. spell_queue:queue_spell_target (priority-based queuing)
---
--- @param spell_data_category table Spell data table (spell_data.builders, spell_data.finishers, etc.)
--- @param spell_key string Spell key in category (e.g., "sinister_strike", "eviscerate")
--- @param local_player game_object Player character
--- @param target game_object|nil Target (nil for self-cast abilities)
--- @param config table Configuration options:
---   - throttle_time: number (seconds to wait between casts, default 0)
---   - queue_priority: number (1-10, default 1)
---   - skip_facing: boolean (default false)
---   - skip_range: boolean (default false)
---   - weapon_check_func: function|nil (custom weapon check, e.g., has_dagger_equipped)
---   - position_check_func: function|nil (custom position check, e.g., is_behind_target)
---   - extra_checks_func: function|nil (custom checks before casting, returns true to continue)
--- @return boolean true if spell was queued successfully
local function try_cast_spell_generic(spell_data_category, spell_key, local_player, target, config)
    -- Validate inputs
    if not local_player or not spell_data_category or not spell_key then
        return false
    end

    local diag_id = get_spell_diag_id(spell_key)
    local diag_enabled = menu_elements and menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
    if diag_enabled then
        log_throttled("spell.try." .. diag_id, 0.35, "[SPELL] TRY " .. diag_id)
    end

    local spell_info = spell_data_category[spell_key]
    if not spell_info then
        if diag_enabled then
            log_throttled("spell.fail." .. diag_id, 1.0, "[SPELL] FAIL " .. diag_id)
        end
        return false
    end

    -- Default config values
    config = config or {}
    local throttle_time = config.throttle_time or 0
    local queue_priority = config.queue_priority or 1
    local skip_facing = config.skip_facing or false
    local skip_range = config.skip_range or false
    local skip_learned = config.skip_learned or false
    local allow_movement = config.allow_movement or false

    -- SAFETY: Block all spells if eating or drinking to avoid breaking recovery
    if rotation_pause and rotation_pause.is_eating_or_drinking(local_player) then
        return false
    end

    -- Throttle check (prevent spam casting)
    if throttle_time > 0 then
        local current_time = core.time()
        local last_time = last_cast_time[spell_key]
        if last_time and (current_time - last_time) < throttle_time then
            if diag_enabled then
                log_throttled("spell.skip." .. diag_id, 1.0, "[SPELL] SKIP " .. diag_id)
            end
            return false
        end
    end

    -- Weapon requirement check (e.g., Backstab requires dagger)
    if config.weapon_check_func and not config.weapon_check_func(local_player, spell_info) then
        if diag_enabled then
            log_throttled("spell.block." .. diag_id, 1.0, "[SPELL] BLOCK " .. diag_id)
        end
        return false
    end

    -- Position requirement check (e.g., Backstab requires behind target)
    if config.position_check_func and not config.position_check_func(local_player, target, spell_info) then
        if diag_enabled then
            log_throttled("spell.block." .. diag_id, 1.0, "[SPELL] BLOCK " .. diag_id)
        end
        return false
    end

    if target and (not __object_safety.same(target,local_player)) then
        local requires_facing = spell_info and spell_info.requires_facing
        if not meets_facing_requirement(local_player, target, requires_facing) then
            if diag_enabled then
                log_throttled("spell.block." .. diag_id, 1.0, "[SPELL] BLOCK " .. diag_id)
            end
            return false
        end
    end

    -- Extra custom checks (e.g., Riposte requires parry buff)
    if config.extra_checks_func and not config.extra_checks_func(local_player, target, spell_info) then
        if diag_enabled then
            log_throttled("spell.block." .. diag_id, 1.0, "[SPELL] BLOCK " .. diag_id)
        end
        return false
    end

    -- Default target to local_player for self-cast abilities
    local cast_target = target or local_player

    -- Try all spell ranks (highest to lowest)
    for i = #spell_info.ids, 1, -1 do
        local spell_id = spell_info.ids[i]

        -- Use spell_helper:is_spell_castable (CRITICAL: Project Silvanas pattern)
        local ok_castable, is_castable = pcall(function()
            return spell_helper:is_spell_castable(
                spell_id,
                local_player,
                cast_target,
                skip_facing,
                skip_range,
                false,        -- skip_usable (always check usability)
                false,        -- skip_controller (always check controller)
                skip_learned  -- skip_learned (configurable - true for racials, false for normal spells)
            )
        end)
        if not ok_castable then
            if diag_enabled then
                log_throttled("spell.err.castable." .. diag_id, 1.0, "[SPELL] ERR castable " .. diag_id)
            end
            is_castable = false
        end

        if is_castable then
            -- Queue spell with appropriate priority
            local ok_queue, success = pcall(function()
                return spell_queue:queue_spell_target(spell_id, cast_target, queue_priority, spell_info.name, allow_movement)
            end)
            if not ok_queue then
                if diag_enabled then
                    log_throttled("spell.err.queue." .. diag_id, 1.0, "[SPELL] ERR queue " .. diag_id)
                end
                success = false
            end

            -- NOTE: spell_queue:queue_spell_target() is a VOID function (returns nil).
            -- Treat nil as success; only explicit `false` means rejection.
            -- pcall errors are caught above (ok_queue=false → success=false).
            if ok_queue and success ~= false then
                -- Update throttle timestamp
                if throttle_time > 0 then
                    last_cast_time[spell_key] = core.time()
                end
                helpers._last_spell_queued_time = core.time()
                helpers._last_spell_queued_key = spell_key
                helpers._last_spell_queued_id = spell_id

                if diag_enabled then
                    log_throttled("spell.ok." .. diag_id, 0.35, "[SPELL] OK " .. diag_id)
                end
                return true
            end

            if diag_enabled then
                log_throttled("spell.fail." .. diag_id, 0.8, "[SPELL] FAIL " .. diag_id)
            end
        end
    end

    if diag_enabled then
        log_throttled("spell.fail." .. diag_id, 0.8, "[SPELL] FAIL " .. diag_id)
    end
    return false
end

---@param unit game_object|nil
---@return string|nil
local function safe_get_guid(unit)
    if not unit then
        return nil
    end
    local ok, guid = pcall(function()
        return unit:get_guid()
    end)
    if not ok or guid == nil then
        return nil
    end
    return tostring(guid)
end

helpers._try_cast_spell_generic = try_cast_spell_generic
helpers._last_spell_queued_time = helpers._last_spell_queued_time or 0.0
helpers._last_spell_queued_key = helpers._last_spell_queued_key or nil
helpers._last_spell_queued_id = helpers._last_spell_queued_id or nil

--- Attempts to cast a combo point builder ability.
--- Builders generate 1 combo point and cost 35-60 energy.
--- Priority: Backstab (Dagger+Behind) > Hemorrhage > Sinister Strike > Ghostly Strike
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @param builder_name string Builder key ("sinister_strike", "backstab", "hemorrhage", "ghostly_strike")
--- @return boolean true if builder was queued successfully
function helpers:try_cast_builder(local_player, target, builder_name)
    return try_cast_spell_generic(spell_data.builders, builder_name, local_player, target, {
        throttle_time = 0.15,  -- Fast spam prevention
        queue_priority = 1,    -- Lowest priority (builders)
        position_check_func = function(lp, tgt, spell_info)
            -- Backstab requires behind target
            if spell_info.requires_facing == "behind" then
                return self:is_behind_target(lp, tgt)
            end
            return true
        end
    })
end

--- Attempts to cast a finisher ability (consumes combo points).
--- Finishers consume 1-5 combo points and cost 25-35 energy.
--- Examples: Eviscerate (damage), Slice and Dice (buff), Kidney Shot (stun)
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @param finisher_name string Finisher key ("eviscerate", "slice_and_dice", "kidney_shot", etc.)
--- @return boolean true if finisher was queued successfully
function helpers:try_cast_finisher(local_player, target, finisher_name)
    return try_cast_spell_generic(spell_data.finishers, finisher_name, local_player, target, {
        throttle_time = 0.15,
        queue_priority = 2  -- Higher priority than builders
    })
end

--- Attempts to cast a crowd control ability.
--- CC abilities include interrupts (Kick), incapacitates (Gouge, Blind), and stuns (Kidney Shot).
--- Higher throttle (0.5s) for more deliberate CC usage.
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @param cc_name string CC key ("kick", "gouge", "blind", "kidney_shot")
--- @return boolean true if CC was queued successfully
function helpers:try_cast_cc(local_player, target, cc_name)
    return try_cast_spell_generic(spell_data.cc, cc_name, local_player, target, {
        throttle_time = 0.5,   -- Slower throttle for deliberate CC
        queue_priority = 3     -- High priority (CC > finishers)
    })
end

--- Attempts to cast a cooldown ability (self-cast buffs).
--- Cooldowns include: Adrenaline Rush, Blade Flurry, Cold Blood, Preparation, Vanish.
--- No throttle (instant-cast, use cooldown system for gating).
---
--- @param local_player game_object Player character
--- @param cooldown_name string Cooldown key ("adrenaline_rush", "blade_flurry", "cold_blood", etc.)
--- @return boolean true if cooldown was queued successfully
function helpers:try_cast_cooldown(local_player, cooldown_name)
    local success = try_cast_spell_generic(spell_data.cooldowns, cooldown_name, local_player, nil, {
        throttle_time = 0.35,  -- Prevent queue-spam before cooldown state updates
        queue_priority = 2,    -- Same as finishers
        skip_facing = true,    -- Self-cast, no facing requirement
        skip_range = true      -- Self-cast, no range requirement
    })

    -- Track Vanish time for lockout window
    if success and cooldown_name == "vanish" then
        last_vanish_time = core.time()
    end

    return success
end

---@param local_player game_object
---@return boolean
function helpers:is_vanish_attack_suppressed(local_player)
    if not local_player then
        return false
    end

    local lockout_sec = 2.0
    local now = core.time()

    if self:has_buff(local_player, "vanish") and last_vanish_time <= 0.0 then
        -- Covers manual Vanish casts outside the rotation: first time we observe the buff, start lockout.
        last_vanish_time = now
    end

    return (now - last_vanish_time) < lockout_sec
end

-- ============================================================================
-- COOLDOWN CHECKS
-- ============================================================================

---@param cooldown_name string
---@return boolean
--- Simplified cooldown check - direct framework call
function helpers:is_cooldown_ready(cooldown_name)
    local cd = spell_data.cooldowns[cooldown_name]
    if not cd then return false end
    return not spell_helper:is_spell_on_cooldown(cd.ids[1])
end

---@return number
function helpers:get_adrenaline_rush_timing_mode()
    if not menu_elements then
        return 1
    end
    return get_menu_combo(menu_elements.adrenaline_rush_timing_mode, 1)
end

---@return number
function helpers:get_adrenaline_rush_tick_safety_ms()
    if not menu_elements then
        return 150
    end
    return get_menu_int(menu_elements.adrenaline_rush_tick_safety_ms, 150)
end

---@param local_player game_object
---@return boolean
--- If AR is armed, this function either casts it at the right tick window or blocks rotation until it can.
function helpers:try_handle_pending_adrenaline_rush(local_player)
    if not ar_timing.is_armed() then
        return false
    end

    if not local_player or not local_player:is_valid() then
        self:log_throttled("ar.clear.invalid", 1.0, "[Rogue] AR: cleared (invalid player)")
        ar_timing.clear()
        return false
    end

    if self:has_buff(local_player, "adrenaline_rush") then
        self:log_throttled("ar.clear.active", 1.0, "[Rogue] AR: cleared (already active)")
        ar_timing.clear()
        return false
    end

    if not self:is_cooldown_ready("adrenaline_rush") then
        self:log_throttled("ar.clear.cd", 1.0, "[Rogue] AR: cleared (cooldown not ready)")
        ar_timing.clear()
        return false
    end

    local mode = self:get_adrenaline_rush_timing_mode()
    if mode ~= 2 then
        self:log_throttled("ar.clear.mode", 1.0, "[Rogue] AR: cleared (mode not tick-timed)")
        ar_timing.clear()
        return false
    end

    local safety_ms = self:get_adrenaline_rush_tick_safety_ms()
    local ms_to_tick = resource_ticks.get():energy_ms_to_next_tick()
    local gcd_ms = safe_get_gcd_remains_ms(local_player)

    if ms_to_tick <= (safety_ms + gcd_ms) then
        self:log_throttled(
            "ar.cast.attempt",
            0.5,
            string.format("[Rogue] AR: attempt cast (tick_in=%.0fms, safety=%dms, gcd=%.0fms)", ms_to_tick, safety_ms, gcd_ms)
        )
        if self:try_cast_cooldown(local_player, "adrenaline_rush") then
            self:log_throttled("ar.cast.success", 0.5, "[Rogue] AR: cast success")
            ar_timing.clear()
        end
        return true
    end

    self:log_throttled(
        "ar.wait",
        1.0,
        string.format("[Rogue] AR: armed, waiting (tick_in=%.0fms, safety=%dms, gcd=%.0fms)", ms_to_tick, safety_ms, gcd_ms)
    )
    -- Armed: wait for the tick window (block the rest of the rotation).
    return true
end

---@param local_player game_object
---@return boolean
function helpers:try_cast_adrenaline_rush(local_player)
    if not local_player then
        return false
    end

    if self:has_buff(local_player, "adrenaline_rush") then
        self:log_throttled("ar.skip.active", 1.0, "[Rogue] AR: skip (already active)")
        ar_timing.clear()
        return false
    end

    if not self:is_cooldown_ready("adrenaline_rush") then
        self:log_throttled("ar.skip.cd", 1.0, "[Rogue] AR: skip (cooldown not ready)")
        ar_timing.clear()
        return false
    end

    local mode = self:get_adrenaline_rush_timing_mode()
    if mode ~= 2 then
        ar_timing.clear()
        return self:try_cast_cooldown(local_player, "adrenaline_rush")
    end

    local safety_ms = self:get_adrenaline_rush_tick_safety_ms()
    if not ar_timing.is_armed() then
        ar_timing.arm(safety_ms)
        local ms_to_tick = resource_ticks.get():energy_ms_to_next_tick()
        local gcd_ms = safe_get_gcd_remains_ms(local_player)
        self:log_throttled(
            "ar.arm",
            0.5,
            string.format("[Rogue] AR: armed (tick_in=%.0fms, safety=%dms, gcd=%.0fms)", ms_to_tick, safety_ms, gcd_ms)
        )
    end

    local gcd_ms = safe_get_gcd_remains_ms(local_player)
    local ms_to_tick = resource_ticks.get():energy_ms_to_next_tick()

    if ms_to_tick <= (safety_ms + gcd_ms) then
        if self:try_cast_cooldown(local_player, "adrenaline_rush") then
            self:log_throttled("ar.cast.success", 0.5, "[Rogue] AR: cast success")
            ar_timing.clear()
        end
    end

    -- Consume frame: once conditions are met, we commit and wait for tick window.
    return true
end

-- ============================================================================
-- DEFENSIVE ABILITIES (RIPOSTE)
-- ============================================================================

--- Attempts to cast Riposte after parrying an attack.
--- Riposte is a defensive counter-attack (Combat talent, Level 20+).
--- Deals 150% weapon damage and disarms target for 6 seconds.
--- Only available after parrying (spell_helper checks parry buff automatically).
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @return boolean true if Riposte was queued successfully
function helpers:try_cast_riposte(local_player, target)
    return try_cast_spell_generic(spell_data.defensive, "riposte", local_player, target, {
        throttle_time = 0,
        queue_priority = 2  -- Defensive priority (same as finishers)
        -- Note: Parry buff check handled by spell_helper:is_spell_castable
    })
end

--- Scans nearby enemies for Elite/Boss targets and returns best threat evaluation target.
--- Prioritizes Elite/Boss enemies within melee range for threat checks.
--- Falls back to current target if no Elite/Boss found nearby.
--- @param local_player game_object Player character
--- @param current_target game_object Current target
--- @return game_object|nil Best target for threat evaluation
--- @return number Threat percent from best target
--- @return boolean Is tanking status from best target
local function get_elite_threat_target(local_player, current_target)
    if not local_player or not current_target then
        return nil, 0, false
    end

    -- Check if current target is Elite/Boss
    local current_is_elite = false
    local ok_class, classification = pcall(function()
        return current_target:get_classification()
    end)
    if ok_class and classification then
        current_is_elite = classification >= enums.classification.ELITE
    end

    -- If current target is already Elite/Boss, use it directly
    if current_is_elite then
        local ok_threat, threat_info = pcall(function()
            return local_player:get_threat_situation(current_target)
        end)

        if ok_threat and threat_info then
            return current_target,
                   threat_info.threat_percent or 0,
                   threat_info.is_tanking or false
        end

        -- Fallback to old API if threat_situation fails
        local ok_pct, threat_pct = pcall(function()
            return current_target:get_threat_percent(local_player) or 0
        end)
        return current_target, (ok_pct and threat_pct or 0), false
    end

    -- Current target is NOT Elite/Boss, scan for nearby Elite/Boss enemies
    local player_pos = local_player:get_position()
    if not player_pos then
        -- Fallback to current target
        local ok_threat, threat_info = pcall(function()
            return local_player:get_threat_situation(current_target)
        end)

        if ok_threat and threat_info then
            return current_target,
                   threat_info.threat_percent or 0,
                   threat_info.is_tanking or false
        end

        local ok_pct, threat_pct = pcall(function()
            return current_target:get_threat_percent(local_player) or 0
        end)
        return current_target, (ok_pct and threat_pct or 0), false
    end

    -- Get nearby enemies (5 yard melee range for Feint effect)
    local ok_enemies, nearby_enemies = pcall(function()
        return unit_helper:get_enemy_list_around(player_pos, 5.0, false, false, false, false)
    end)

    if not ok_enemies or not nearby_enemies then
        -- Fallback to current target
        local ok_threat, threat_info = pcall(function()
            return local_player:get_threat_situation(current_target)
        end)

        if ok_threat and threat_info then
            return current_target,
                   threat_info.threat_percent or 0,
                   threat_info.is_tanking or false
        end

        local ok_pct, threat_pct = pcall(function()
            return current_target:get_threat_percent(local_player) or 0
        end)
        return current_target, (ok_pct and threat_pct or 0), false
    end

    -- Find Elite/Boss with highest threat
    local best_elite = nil
    local best_threat = 0
    local best_is_tanking = false

    for _, enemy in __object_safety.live_ipairs(nearby_enemies) do
        if enemy and enemy:is_valid() and enemy:is_alive() then
            local ok_check, is_elite = pcall(function()
                local class = enemy:get_classification()
                return class >= enums.classification.ELITE
            end)

            if ok_check and is_elite then
                local ok_threat, threat_info = pcall(function()
                    return local_player:get_threat_situation(enemy)
                end)

                if ok_threat and threat_info then
                    local threat_pct = threat_info.threat_percent or 0
                    local is_tanking = threat_info.is_tanking or false

                    -- Prioritize: is_tanking > highest threat_percent
                    if is_tanking and not best_is_tanking then
                        best_elite = enemy
                        best_threat = threat_pct
                        best_is_tanking = true
                    elseif is_tanking == best_is_tanking and threat_pct > best_threat then
                        best_elite = enemy
                        best_threat = threat_pct
                        best_is_tanking = is_tanking
                    end
                end
            end
        end
    end

    -- If found Elite/Boss nearby, use that for threat evaluation
    if best_elite then
        return best_elite, best_threat, best_is_tanking
    end

    -- Fallback to current target (not Elite/Boss)
    local ok_threat, threat_info = pcall(function()
        return local_player:get_threat_situation(current_target)
    end)

    if ok_threat and threat_info then
        return current_target,
               threat_info.threat_percent or 0,
               threat_info.is_tanking or false
    end

    -- Final fallback to old API
    local ok_pct, threat_pct = pcall(function()
        return current_target:get_threat_percent(local_player) or 0
    end)
    return current_target, (ok_pct and threat_pct or 0), false
end

---@param local_player game_object
---@param target game_object
---@return boolean
function helpers:try_use_feint(local_player, target)
    if not local_player or not target then
        return false
    end

    -- Check if feint is enabled in menu
    if not menu_elements.auto_feint_enabled or not menu_elements.auto_feint_enabled:get_state() then
        return false
    end

    local feint = spell_data.defensive.feint
    if not feint then
        return false
    end

    -- Only use in group scenarios (use pcall for safety)
    local ok_party, is_in_party = pcall(function()
        return local_player:is_in_party()
    end)
    local ok_raid, is_in_raid = pcall(function()
        return local_player:is_in_raid()
    end)

    local in_group = (ok_party and is_in_party) or (ok_raid and is_in_raid)
    if not in_group then
        return false
    end

    -- Check if instance-only mode is enabled
    local instance_only = false
    if menu_elements.auto_feint_instance_only and menu_elements.auto_feint_instance_only.get_state then
        instance_only = menu_elements.auto_feint_instance_only:get_state()
    end

    -- If instance-only mode, verify we're in a dungeon/raid
    if instance_only then
        local ok_instance, instance_type = pcall(function()
            return core.get_instance_type()
        end)

        if ok_instance and instance_type then
            -- Valid instance types: "party" (5-man dungeon), "raid" (raid instance)
            -- Invalid: "none" (world), "pvp" (battleground), "arena"
            if instance_type ~= "party" and instance_type ~= "raid" then
                return false
            end
        else
            -- If instance check fails, default to allow (safer for actual dungeons)
        end
    end

    -- Check if spell is learned (use highest rank available)
    local spell_id = nil
    for i = #feint.ids, 1, -1 do
        if core.spell_book.is_spell_learned(feint.ids[i]) then
            spell_id = feint.ids[i]
            break
        end
    end

    if not spell_id then
        return false
    end

    local energy = local_player:get_power(enums.power_type.ENERGY)

    -- Check energy cost
    if energy < feint.energy_cost then
        return false
    end

    -- Check if spell is on cooldown
    if spell_helper:is_spell_on_cooldown(spell_id) then
        return false
    end

    -- Check if we already have the Feint buff active (any rank)
    local has_feint_buff = false
    for _, feint_id in ipairs(feint.ids) do
        if local_player:has_aura(feint_id) then
            has_feint_buff = true
            break
        end
    end

    if has_feint_buff then
        return false
    end

    -- Get threat threshold from menu
    local threat_threshold = 80
    if menu_elements.auto_feint_threat_threshold and menu_elements.auto_feint_threat_threshold.get then
        threat_threshold = menu_elements.auto_feint_threat_threshold:get() or 80
    end

    -- Check if reactive mode (is_tanking) is enabled
    local reactive_mode = true  -- Default: enabled (user wants "Beides kombiniert")
    if menu_elements.auto_feint_reactive_mode and menu_elements.auto_feint_reactive_mode.get_state then
        reactive_mode = menu_elements.auto_feint_reactive_mode:get_state()
    end

    -- Get threat evaluation from Elite/Boss priority target
    local _eval_target, threat_percent, is_tanking = get_elite_threat_target(local_player, target)

    -- Trigger conditions: "Beides kombiniert" - Preventive OR Reactive
    -- Preventive: threat_percent >= threshold
    -- Reactive: is_tanking (if reactive_mode enabled)
    local should_cast = false

    -- Check preventive condition
    if threat_percent >= threat_threshold then
        should_cast = true
    end

    -- Check reactive condition (only if reactive mode enabled)
    if reactive_mode and is_tanking then
        should_cast = true
    end

    if not should_cast then
        return false
    end

    -- Cast Feint using queue_spell_target (self-cast)
    spell_queue:queue_spell_target(spell_id, local_player, 1, feint.name)
    return true  -- fire-and-forget: queue accepted if we reach this point
end

-- ============================================================================
-- AUTO CLOAK OF SHADOWS (TBC)
-- ============================================================================

---@param local_player game_object
---@param target game_object|nil
---@return boolean
function helpers:try_use_cloak_of_shadows(local_player, target)
    if not local_player or not menu_elements then
        return false
    end

    if not menu_elements.auto_cloak_enabled or not menu_elements.auto_cloak_enabled:get_state() then
        return false
    end

    local now = core.time()
    if (now - last_cloak_check_time) < 0.25 then
        return false
    end
    last_cloak_check_time = now

    if not unit_helper:is_in_combat(local_player) then
        return false
    end

    if self:has_buff(local_player, "cloak_of_shadows") then
        return false
    end

    -- Check learned/cd
    local cloak = spell_data.defensive and spell_data.defensive.cloak_of_shadows
    if not cloak or not cloak.ids then
        return false
    end

    local learned = false
    for _, id in ipairs(cloak.ids) do
        if core.spell_book.is_spell_learned(id) then
            learned = true
            break
        end
    end
    if not learned then
        return false
    end

    local should_cast = false

    -- HP emergency usage
    local hp = local_player:get_health_percentage() or 100
    local hp_threshold = (menu_elements.auto_cloak_hp_threshold and menu_elements.auto_cloak_hp_threshold.get and menu_elements.auto_cloak_hp_threshold:get()) or 45
    if hp_threshold > 0 and hp <= hp_threshold then
        should_cast = true
    end

    -- Magic/Curse debuffs
    if not should_cast then
        local debuffs = local_player:get_debuffs()
        if debuffs and type(debuffs) == "table" then
            for _, debuff in ipairs(debuffs) do
                if debuff and (debuff.type == enums.buff_type.MAGIC or debuff.type == enums.buff_type.CURSE) then
                    should_cast = true
                    break
                end
            end
        end
    end

    -- If current target is casting on us, allow proactive cloak.
    if not should_cast and target and target.is_valid and target:is_valid() and target:is_alive() then
        local ok_casting, is_casting = pcall(function()
            return target:is_casting_spell() == true
        end)
        if ok_casting and is_casting then
            local ok_tgt, t = pcall(function()
                return target:get_target()
            end)
            if ok_tgt and t and (__object_safety.same(t,local_player)) then
                should_cast = true
            end
        end
    end

    if not should_cast then
        return false
    end

    return try_cast_spell_generic(spell_data.defensive, "cloak_of_shadows", local_player, nil, {
        throttle_time = 0.25,
        queue_priority = 10,
        skip_facing = true,
        skip_range = true,
        skip_learned = true
    }) == true
end


---@param local_player game_object
---@return boolean
function helpers:is_in_stealth(local_player)
    return self:has_buff(local_player, "stealth") or self:has_buff(local_player, "vanish")
end

-- ============================================================================
-- CONTROL PANEL TOGGLE CHECKS
-- ============================================================================

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

--- Generic toggle checker - replaces 5 duplicate functions
--- @param toggle_name string Name of the toggle element
--- @return boolean true if toggle is enabled
local function is_toggle_active(toggle_name)
    if not menu_elements or not menu_elements[toggle_name] then
        return false
    end
    return plugin_helper:is_toggle_enabled(menu_elements[toggle_name])
end

---@return boolean
function helpers:is_cooldowns_toggle_active()
    return is_toggle_active("cooldowns_toggle")
end

---@return boolean
function helpers:is_aoe_toggle_active()
    return is_toggle_active("aoe_toggle")
end

---@return boolean
function helpers:is_burst_mode_always()
    if not menu_elements or not menu_elements.burst_mode then
        return false
    end

    local ok, value = pcall(function()
        return menu_elements.burst_mode:get()
    end)

    return ok and value == 2
end

---@return boolean
function helpers:is_cc_toggle_active()
    return is_toggle_active("cc_toggle")
end

---@return boolean
function helpers:is_pickpocket_toggle_active()
    return is_toggle_active("pickpocket_toggle")
end

---@return boolean
function helpers:is_engineering_toggle_active()
    return is_toggle_active("engineering_toggle")
end

---@return boolean
function helpers:is_gouge_energy_regen_toggle_active()
    return is_toggle_active("gouge_energy_regen_toggle")
end

---@return boolean
function helpers:is_pvp_mode_active()
    local enabled = false
    if menu_elements and menu_elements.enable_pvp_mode and menu_elements.enable_pvp_mode.get_state then
        enabled = menu_elements.enable_pvp_mode:get_state() == true
    end

    local toggled = is_toggle_active("pvp_mode_toggle")
    return enabled or toggled
end

---@return boolean
function helpers:is_pvp_scenario()
    if pvp_utiltiy and pvp_utiltiy.is_pvp_scenario then
        return pvp_utiltiy:is_pvp_scenario() == true
    end
    return false
end

---@param local_player game_object
---@return boolean
function helpers:has_deadly_throw_interrupt_gloves_equipped(local_player)
    if not local_player then
        return false
    end

    local gloves = {
        [25834] = true, -- Gladiator's Leather Gloves
        [31998] = true, -- Merciless Gladiator's Leather Gloves
        [33700] = true, -- Vengeful Gladiator's Leather Gloves
        [35032] = true  -- Brutal Gladiator's Leather Gloves
    }

    local ok_slot, slot_data = pcall(function()
        return local_player:get_item_at_inventory_slot(10)
    end)
    if not ok_slot or not slot_data or not slot_data.object then
        return false
    end

    local ok_id, item_id = pcall(function()
        return slot_data.object:get_item_id()
    end)

    return (ok_id and item_id and gloves[item_id] == true) or false
end

-- ============================================================================
-- ENGINEERING EXPLOSIVES
-- ============================================================================

---@param local_player game_object
---@param item_id number
---@return boolean
local function is_item_ready(local_player, item_id)
    if not has_item_in_inventory(local_player, item_id) then
        return false
    end

    -- Check item cooldown (protected call in case of API issues)
    local ok, cooldown = pcall(function()
        return local_player:get_item_cooldown(item_id)
    end)

    if ok and cooldown and cooldown > 0.0 then
        return false
    end

    return true
end

---@param local_player game_object
---@param list table
---@param predicate fun(entry: table): boolean|nil|nil
---@return table|nil
local function get_available_item_from_list(local_player, list, predicate)
    for i = #list, 1, -1 do
        local entry = list[i]
        if not predicate or predicate(entry) then
            if is_item_ready(local_player, entry.item_id) then
                return entry
            end
        end
    end
    return nil
end

local SAPPER_MAX_SELF_DAMAGE = 750
local SAPPER_DEFAULT_SAFETY_BUFFER = 200
local SAPPER_DEFAULT_MIN_HP_PCT = 95

---@param local_player game_object
---@return boolean
local function can_survive_sapper(local_player)
    if not local_player then
        return false
    end

    local buffer = SAPPER_DEFAULT_SAFETY_BUFFER
    if menu_elements and menu_elements.engineering_sapper_self_damage_buffer then
        local ok_buffer, val = pcall(function()
            return menu_elements.engineering_sapper_self_damage_buffer:get()
        end)
        if ok_buffer and val ~= nil then
            buffer = val
        end
    end

    local min_hp_pct = SAPPER_DEFAULT_MIN_HP_PCT
    if menu_elements and menu_elements.engineering_sapper_min_hp_pct then
        local ok_pct, val = pcall(function()
            return menu_elements.engineering_sapper_min_hp_pct:get()
        end)
        if ok_pct and val ~= nil then
            min_hp_pct = val
        end
    end

    local ok_hp, hp = pcall(function()
        return local_player:get_health()
    end)
    if ok_hp and hp and hp > (SAPPER_MAX_SELF_DAMAGE + buffer) then
        return true
    end

    local ok_pct, hp_pct = pcall(function()
        return local_player:get_health_percentage()
    end)
    if ok_pct and hp_pct and hp_pct >= min_hp_pct then
        return true
    end

    return false
end

---@param local_player game_object
---@param enemy game_object
---@return boolean
local function is_enemy_engaged_with_player(local_player, enemy)
    if not enemy then
        return false
    end

    local ok_valid, is_valid = pcall(function()
        return enemy:is_valid()
    end)
    if not ok_valid or not is_valid then
        return false
    end

    local ok_unit, is_unit = pcall(function()
        return enemy:is_unit()
    end)
    if not ok_unit or not is_unit then
        return false
    end

    local ok_player, is_player = pcall(function()
        return enemy:is_player()
    end)
    if ok_player and is_player then
        return false
    end

    local ok_dead, is_dead = pcall(function()
        return enemy:is_dead()
    end)
    if ok_dead and is_dead then
        return false
    end

    local ok_friend, is_friend = pcall(function()
        return enemy:is_friend_with(local_player)
    end)
    if ok_friend and is_friend then
        return false
    end

    if not unit_helper:is_in_combat(enemy) then
        -- Allow if we are stealthed (potential opener)
        local stealthed = false
        pcall(function() stealthed = local_player:buff_up(spell_data.buffs.stealth) == true end)
        if stealthed then return true end

        -- Allow if target is our current target (explicit intent)
        local current_target = local_player:get_target()
        if current_target and (__object_safety.same(current_target,enemy)) then
            return true
        end

        return false
    end

    local ok_can_attack, can_attack = pcall(function()
        return local_player:can_attack(enemy)
    end)
    if ok_can_attack and not can_attack then
        return false
    end

    if pvp_utiltiy:is_crowd_controlled(enemy,
        pvp_utiltiy.cc_flags.combine(pvp_utiltiy.cc_flags.SAP, pvp_utiltiy.cc_flags.INCAPACITATE, pvp_utiltiy.cc_flags.DISORIENT),
        1000) then
        return false
    end

    local enemy_target = enemy:get_target()
    if not enemy_target then
        -- FALLBACK: If target hasn't selected anyone yet but is hostile/enemy,
        -- consider them engaged enough to attack (essential for pulling/initiating).
        local ok, is_enemy = pcall(function() return enemy:is_enemy_with(local_player) end)
        if ok and is_enemy then
            return true
        end
        return false
    end

    if (__object_safety.same(enemy_target,local_player)) then
        return true
    end

    local ok_party, is_party_target = pcall(function()
        return enemy_target:is_party_member()
    end)
    if ok_party and is_party_target then
        return true
    end

    local ok_pet, is_pet = pcall(function()
        return enemy_target:is_pet()
    end)
    if ok_pet and is_pet then
        local owner = enemy_target:get_owner()
        if owner then
            -- Pet owner must be the local player or a party member
            if (__object_safety.same(owner,local_player)) then
                return true
            end
            local ok_owner_party, is_owner_party = pcall(function()
                return owner:is_party_member()
            end)
            if ok_owner_party and is_owner_party then
                return true
            end
        end
    end

    return false
end

---@param local_player game_object
---@param enemy game_object
---@return boolean
function helpers:is_enemy_engaged_with_player(local_player, enemy)
    return is_enemy_engaged_with_player(local_player, enemy)
end

-- ============================================================================
-- AOE SAFETY GATE (Hardcore CC-Safe Mechanics)
-- ============================================================================

--- Checks if AoE abilities (Explosives, Blade Flurry) are safe to use
--- Blocks AoE if CC'd targets or unpulled mobs would be hit
---
--- @param local_player game_object Player character
--- @param center_pos vec3 Center position of AoE effect
--- @param radius number Radius of AoE effect in yards
--- @param aoe_type string Type of AoE for debug logging ("EXPLOSIVE", "BLADE_FLURRY", etc.)
--- @return boolean true if AoE is safe to use, false if blocked
function helpers:is_aoe_allowed(local_player, center_pos, radius, aoe_type)
    -- Check if hardcore safe AoE toggle is enabled
    if not menu_elements.hardcore_safe_aoe then
        return true  -- Toggle not initialized, allow AoE
    end

    if not menu_elements.hardcore_safe_aoe:get_state() then
        return true  -- Safety disabled, allow AoE
    end

    -- Scan for enemies in AoE radius
    local enemies_in_radius = unit_helper:get_enemy_list_around(center_pos, radius)

    if not enemies_in_radius then
        return true  -- No enemies found, safe
    end

    for _, enemy in __object_safety.live_ipairs(enemies_in_radius) do
        -- Validate enemy object
        if not enemy or not enemy:is_valid() then
            goto continue
        end

        -- BLOCK CONDITION 1: Enemy is CC'd (damage would break CC)
        local is_sapped = enemy:is_sapped(100)
        local is_incap = enemy:is_incap(100)
        local is_disoriented = enemy:is_disoriented(100)

        if is_sapped or is_incap or is_disoriented then
            if menu_elements.debug_hardcore_safety and menu_elements.debug_hardcore_safety:get_state() then
                log_throttled("aoe_blocked.cc", 5.0, "[AOE] BLOCKED (CC)")
            end
            return false
        end

        -- BLOCK CONDITION 2: Enemy is unpulled (would aggro new mob)
        if not is_enemy_engaged_with_player(local_player, enemy) then
            if menu_elements.debug_hardcore_safety and menu_elements.debug_hardcore_safety:get_state() then
                log_throttled("aoe_blocked.unpulled", 5.0, "[AOE] BLOCKED (UNPULLED)")
            end
            return false
        end

        ::continue::
    end

    -- All checks passed, AoE is safe
    return true
end

---@param local_player game_object
---@param enemies game_object[]
---@param radius number
---@param max_range number
---@return vec3|nil best_position, number best_count
local function get_best_explosive_position(local_player, enemies, radius, max_range)
    local player_pos = local_player:get_position()
    if not player_pos then
        return nil, 0
    end

    if #enemies == 0 then
        return nil, 0
    end

    -- Filter enemies within range and cache positions
    local positions = {}
    for _, enemy in __object_safety.live_ipairs(enemies) do
        local pos = enemy:get_position()
        if pos and pos:dist_to_ignore_z(player_pos) <= max_range then
            table.insert(positions, pos)
        end
    end

    if #positions == 0 then
        return nil, 0
    end

    if #positions == 1 then
        return positions[1], 1
    end

    -- Find position that hits most enemies (simple O(n²) algorithm)
    -- Classic WoW rarely has >10 enemies grouped, so this is fine
    local best_position, best_count = nil, 0
    for _, pos_i in ipairs(positions) do
        local count = 0
        for _, pos_j in ipairs(positions) do
            if pos_j:dist_to_ignore_z(pos_i) <= radius then
                count = count + 1
            end
        end
        if count > best_count then
            best_count = count
            best_position = pos_i
        end
    end

    return best_position, best_count
end

---@param local_player game_object
---@return boolean
function helpers:try_use_engineering_explosive(local_player)
    if not local_player or not menu_elements then
        return false
    end

    if not self:is_engineering_toggle_active() then
        return false
    end

    if not unit_helper:is_in_combat(local_player) then
        return false
    end

    -- Allow explosive usage while moving (items can be used on the move)
    -- if local_player:is_moving() then
    --     return false
    -- end

    local cast_end_time = local_player:get_active_spell_cast_end_time()
    if cast_end_time > 0.0 then
        return false
    end

    local channel_end_time = local_player:get_active_channel_cast_end_time()
    if channel_end_time > 0.0 then
        return false
    end

    local now = core.time()
    if (now - last_engineering_use_time) < 1.0 then
        return false
    end

    -- OPTIMIZATION: Early exit if no explosives in inventory (skip expensive enemy enumeration)
    local has_sapper = get_available_item_from_list(local_player, engineering_items.sapper, function() return true end) ~= nil
    local has_bombs = get_available_item_from_list(local_player, engineering_items.bombs, function() return true end) ~= nil
    local has_dynamite = get_available_item_from_list(local_player, engineering_items.dynamite, function() return true end) ~= nil
    local has_special = get_available_item_from_list(local_player, engineering_items.special_explosives, function() return true end) ~= nil

    if not (has_sapper or has_bombs or has_dynamite or has_special) then
        return false
    end

    -- Get nearby enemies instead of just engaged enemies for better AoE detection
    local player_pos = local_player:get_position()
    if not player_pos then
        return false
    end

    local all_enemies = unit_helper:get_enemy_list_around(player_pos, 30.0)

    -- Filter to only valid, alive enemies
    local enemies = {}
    for _, enemy in __object_safety.live_ipairs(all_enemies) do
        if enemy and enemy:is_valid() and enemy:is_unit() and not enemy:is_dead() then
            table.insert(enemies, enemy)
        end
    end

    if #enemies == 0 then
        return false
    end

    local min_targets = menu_elements.engineering_min_targets and menu_elements.engineering_min_targets:get() or 2
    local sapper_min_targets = menu_elements.engineering_sapper_min_targets and menu_elements.engineering_sapper_min_targets:get() or 4
    local max_range = 25.0

    -- IMPROVED: Check Sapper first (larger radius), then regular bombs/dynamite
    local prefer_stun = false
    if self:is_cc_toggle_active() then
        prefer_stun = menu_elements.engineering_prefer_stun and menu_elements.engineering_prefer_stun:get_state() or true
    end

    -- Try Sapper Charge first (10 yard radius, high min target requirement)
    local sapper_radius = 10.0
    local sapper_position, sapper_count = get_best_explosive_position(local_player, enemies, sapper_radius, max_range)
    if sapper_count >= sapper_min_targets and sapper_position then
        local sapper_item = get_available_item_from_list(local_player, engineering_items.sapper, nil)
        if sapper_item then
            if not can_survive_sapper(local_player) then
                if menu_elements.debug_hardcore_safety and menu_elements.debug_hardcore_safety:get_state() then
                    log_throttled("sapper.blocked.self_damage", 5.0, "[AOE] BLOCKED (SAPPER SELF-DAMAGE)")
                end
            elseif self:is_aoe_allowed(local_player, sapper_position, sapper_radius, "EXPLOSIVE_SAPPER") then
                -- CC-Safe AoE check before throwing
                local diag_enabled = menu_elements and menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
                local diag_id = get_item_diag_id("engineering_explosive")
                if diag_enabled then
                    log_throttled("item.try." .. diag_id, 2.0, "[ITEM] TRY " .. diag_id)
                end

                local ok_queue = pcall(function()
                    spell_queue:queue_item_position(sapper_item.item_id, sapper_position, 6, "Engineering: " .. sapper_item.name)
                end)

                if diag_enabled then
                    if ok_queue then
                        log_throttled("item.ok." .. diag_id, 2.0, "[ITEM] OK " .. diag_id)
                    else
                        log_throttled("item.fail." .. diag_id, 2.0, "[ITEM] FAIL " .. diag_id)
                    end
                end

                if ok_queue then
                    last_engineering_use_time = now
                end
                return ok_queue
            end
        end
    end

    -- Regular bombs/dynamite (5 yard radius - actual Classic radius)
    local bomb_radius = 5.0
    local best_position, best_count = get_best_explosive_position(local_player, enemies, bomb_radius, max_range)

    -- CRITICAL: Only throw if we can hit at least min_targets enemies
    if not best_position or best_count < min_targets then
        return false
    end

    local item = nil

    -- Prefer stun bombs if CC toggle active
    if prefer_stun then
        item = get_available_item_from_list(local_player, engineering_items.bombs, function(entry)
            return entry.can_stun
        end)
    end

    -- Fallback to any bomb
    if not item then
        item = get_available_item_from_list(local_player, engineering_items.bombs, nil)
    end

    -- Fallback to dynamite
    if not item then
        item = get_available_item_from_list(local_player, engineering_items.dynamite, nil)
    end

    -- Fallback to special explosives
    if not item then
        item = get_available_item_from_list(local_player, engineering_items.special_explosives, nil)
    end

    if not item then
        return false
    end

    -- CC-Safe AoE check before throwing
    if not self:is_aoe_allowed(local_player, best_position, bomb_radius, "EXPLOSIVE_BOMB") then
        return false
    end

    local diag_enabled = menu_elements and menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
    local diag_id = get_item_diag_id("engineering_explosive")
    if diag_enabled then
        log_throttled("item.try." .. diag_id, 2.0, "[ITEM] TRY " .. diag_id)
    end

    local ok_queue = pcall(function()
        spell_queue:queue_item_position(item.item_id, best_position, 6, "Engineering: " .. item.name)
    end)

    if diag_enabled then
        if ok_queue then
            log_throttled("item.ok." .. diag_id, 2.0, "[ITEM] OK " .. diag_id)
        else
            log_throttled("item.fail." .. diag_id, 2.0, "[ITEM] FAIL " .. diag_id)
        end
    end

    if ok_queue then
        last_engineering_use_time = now
    end
    return ok_queue
end

-- ============================================================================
-- EMERGENCY HARDCORE SURVIVAL
-- ============================================================================

---@param local_player game_object
---@return boolean
function helpers:try_emergency_vanish_sprint(local_player)
    if not local_player then
        return false
    end

    -- Check if toggle is active
    if not menu_elements or not menu_elements.emergency_enabled then
        return false
    end

    if not menu_elements.emergency_enabled:get_state() then
        return false
    end

    local function get_threshold(slider, fallback_slider)
        local ok_val, val = pcall(function()
            return slider and slider:get()
        end)
        if ok_val and val ~= nil then
            return val
        end

        local ok_fallback, fallback_val = pcall(function()
            return fallback_slider and fallback_slider:get()
        end)
        if ok_fallback and fallback_val ~= nil then
            return fallback_val
        end

        return 20
    end

    -- Check HP thresholds (default 20% each)
    local hp_percent = local_player:get_health_percentage()
    local vanish_threshold = get_threshold(menu_elements.emergency_vanish_threshold, menu_elements.emergency_threshold_legacy)
    local sprint_threshold = get_threshold(menu_elements.emergency_sprint_threshold, menu_elements.emergency_threshold_legacy)

    local should_vanish = hp_percent <= vanish_threshold
    local should_sprint = hp_percent <= sprint_threshold

    if not should_vanish and not should_sprint then
        return false
    end

    local is_stealthed = self:has_buff(local_player, "stealth") or self:has_buff(local_player, "vanish")
    local in_combat = unit_helper:is_in_combat(local_player)
    if not in_combat and not is_stealthed then
        return false
    end

    local function try_cast_emergency_cooldown(cooldown_name)
        local success = try_cast_spell_generic(spell_data.cooldowns, cooldown_name, local_player, nil, {
            throttle_time = 0,
            queue_priority = 10, -- Emergency always wins queue arbitration
            skip_facing = true,
            skip_range = true
        })

        if success and cooldown_name == "vanish" then
            last_vanish_time = core.time()
        end

        return success
    end

    local want_sprint = not self:has_buff(local_player, "sprint")

    -- If already stealthed (usually from Vanish), only handle Sprint follow-up.
    if is_stealthed then
        if should_sprint and want_sprint then
            if try_cast_emergency_cooldown("sprint") then
                return true
            end
            if self:is_cooldown_ready("sprint") then
                return true
            end
        end

        return false
    end

    -- Try Vanish first (drops combat + stealth)
    if in_combat and should_vanish and try_cast_emergency_cooldown("vanish") then
        if should_sprint and want_sprint then
            try_cast_emergency_cooldown("sprint")
        end
        return true
    end

    -- If Vanish can't be used (or isn't desired), Sprint is still a good escape tool.
    if should_sprint and want_sprint then
        if try_cast_emergency_cooldown("sprint") then
            return true
        end
        if self:is_cooldown_ready("sprint") then
            return true
        end
    end

    return false
end

-- ============================================================================
-- AUTO EVASION
-- ============================================================================

---@param local_player game_object
---@return boolean
function helpers:try_use_evasion(local_player)
    if not local_player then
        return false
    end

    -- Check if toggle is active
    if not menu_elements or not menu_elements.auto_evasion_enabled then
        return false
    end

    if not menu_elements.auto_evasion_enabled:get_state() then
        return false
    end

    -- Only use Evasion in combat (prevent DOTs from triggering it out of combat)
    if not local_player:is_in_combat() then
        return false
    end

    -- Check HP threshold (default 40%)
    local hp_percent = local_player:get_health_percentage()
    local threshold = menu_elements.auto_evasion_threshold and menu_elements.auto_evasion_threshold:get() or 40

    if hp_percent > threshold then
        return false
    end

    -- Try to cast Evasion
    if self:try_cast_cooldown(local_player, "evasion") then
        return true
    end

    return false
end

-- ============================================================================
-- EMERGENCY BLIND (Hardcore Safe Mechanics)
-- ============================================================================

--- Attempts to use Blind as emergency CC when health is critical
--- Blind: 10 second disorient, 5 min cooldown, requires Blinding Powder (item 5530)
--- Priority: Vanish first (if no DoTs), Blind if Vanish on CD or DoTs active
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @return boolean true if Blind was cast successfully
function helpers:try_emergency_blind(local_player, target)
    if not local_player or not target then
        return false
    end

    local diag_enabled = menu_elements and menu_elements.rotation_log_enabled and menu_elements.rotation_log_enabled:get_state() == true
    local diag_id = get_spell_diag_id("emergency_blind")

    -- Check if toggle is active
    if not menu_elements or not menu_elements.emergency_blind_enabled then
        return false
    end

    if not menu_elements.emergency_blind_enabled:get_state() then
        return false
    end

    -- VANISH PRIORITY CHECK: If Vanish available and no DoTs, let Vanish handle emergency
    local vanish_available = self:is_cooldown_ready("vanish")
    local all_dot_ids = spell_data.get_all_dot_ids()
    local has_dots = local_player:debuff_up(all_dot_ids)

    if vanish_available and not has_dots then
        return false  -- Vanish takes priority
    end

    -- TRIGGER CONDITION 1: HP threshold check (default 25%)
    local hp_percent = local_player:get_health_percentage()
    local threshold = menu_elements.emergency_blind_threshold and menu_elements.emergency_blind_threshold:get() or 25

    if hp_percent > threshold then
        return false
    end

    -- TRIGGER CONDITION 2: Blind spell ID (2094)
    local blind_id = 2094

    -- Check if Blind is learned
    if not core.spell_book.is_spell_learned(blind_id) then
        return false
    end

    -- TRIGGER CONDITION 3: Blind available (not on cooldown)
    if spell_helper:is_spell_on_cooldown(blind_id) then
        return false
    end

    -- TRIGGER CONDITION 4: Energy available (30 energy cost)
    local energy = local_player:energy_current()
    if energy < 30 then
        return false
    end

    -- TRIGGER CONDITION 5: Blinding Powder available (item ID 5530)
    if not local_player:has_item(5530) then
        return false  -- No reagent
    end

    -- TRIGGER CONDITION 6: Target validation
    if not target:is_valid() or not target:is_alive() then
        return false
    end

    if target:is_friend_with(local_player) then
        return false
    end

    -- TRIGGER CONDITION 7: Target not already CC'd
    local is_sapped = target:is_sapped(1000)
    local is_incap = target:is_incap(1000)
    local is_disoriented = target:is_disoriented(1000)

    if is_sapped or is_incap or is_disoriented then
        return false  -- Don't overlap CC
    end

    local is_castable = spell_helper:is_spell_castable(
        blind_id,
        local_player,
        target,
        false,
        false,
        false,
        false,
        false
    )
    if not is_castable then
        return false
    end

    -- Cast Blind (priority 10 = emergency)
    if diag_enabled then
        log_throttled("spell.try." .. diag_id, 1.0, "[SPELL] TRY " .. diag_id)
    end

    local cast_success = spell_queue:queue_spell_target(blind_id, target, 10, "Emergency Blind")

    if diag_enabled then
        if cast_success then
            log_throttled("spell.ok." .. diag_id, 1.0, "[SPELL] OK " .. diag_id)
        else
            log_throttled("spell.fail." .. diag_id, 1.0, "[SPELL] FAIL " .. diag_id)
        end
    end

    -- Follow-up: Try to bandage during Blind window
    self:try_use_bandage(local_player)

    return true
end

-- ============================================================================
-- ENEMY COUNTING (TTD = Time To Die estimation)
-- ============================================================================
-- Classic WoW API doesn't provide damage tracking, so we use simple heuristics:
-- - HP > 30%: Enemy likely lives >= 4 seconds
-- - HP <= 30%: Estimate TTD = current_hp / 75 DPS (conservative Classic estimate)
-- ============================================================================
---@param target game_object
---@param radius number
---@param min_ttd number|nil Time to die in seconds (optional)
---@return number total_count, number ttd_count
function helpers:get_enemy_counts_cached(target, radius, min_ttd)
    if not target then
        return 0, 0
    end

    local target_pos = target:get_position()
    if not target_pos then
        return 0, 0
    end

    return self:get_enemy_counts_around_position(target_pos, radius, min_ttd)
end

---@param center_pos vec3
---@param radius number
---@param min_ttd number|nil Time to die in seconds (optional)
---@return number total_count, number ttd_count
function helpers:get_enemy_counts_around_position(center_pos, radius, min_ttd)
    if not center_pos then
        return 0, 0
    end

    -- Direct framework call (no caching needed - premature optimization)
    local enemies = unit_helper:get_enemy_list_around(center_pos, radius) or {}
    local total_count = #enemies
    local ttd_count = 0

    if min_ttd and min_ttd > 0 then
        for _, enemy in __object_safety.live_ipairs(enemies) do
            if enemy and enemy:is_valid() then
                local enemy_hp_percent = enemy:get_health_percentage()

                -- TTD heuristic
                if enemy_hp_percent > 30 then
                    ttd_count = ttd_count + 1
                else
                    local estimated_dps = 75
                    local enemy_hp = enemy:get_health() or 0
                    if enemy_hp > 0 then  -- Zero guard for division
                        local estimated_ttd = enemy_hp / estimated_dps
                        if estimated_ttd >= min_ttd then
                            ttd_count = ttd_count + 1
                        end
                    end
                end
            end
        end
    else
        ttd_count = total_count
    end

    return total_count, ttd_count
end

-- ============================================================================
-- INTERRUPT & ENERGY POOLING SYSTEM
-- ============================================================================

-- Track Gouge targets (stores game_object references to check if CC is still active)
local gouge_energy_regen_target = nil
local gouge_energy_regen_time = 0
local gouge_should_bandage = false  -- Track if current Gouge should trigger bandage

-- Gouge timeout settings (prevents rotation from freezing on miss/resist)
local GOUGE_DEBUFF_CHECK_TIMEOUT = 0.3  -- Max time to wait for debuff confirmation (seconds)
local GOUGE_RETRY_COOLDOWN = 2.0        -- Cooldown after failed attempt (prevents spam)

---@param target game_object
---@param debuff_ids number[]
---@return boolean
local function has_debuff_ids(target, debuff_ids)
    if not target or not debuff_ids then
        return false
    end

    local debuff_data = buff_manager:get_debuff_data(target, debuff_ids)
    return debuff_data and debuff_data.is_active or false
end

---@param target game_object
---@return boolean
local function is_gouge_debuff_active(target)
    if not target then
        return false
    end

    local gouge = spell_data.cc.gouge
    if not gouge or not gouge.ids then
        return false
    end

    return has_debuff_ids(target, gouge.ids)
end

---@param local_player game_object
---@param target game_object
---@return boolean should_interrupt, boolean is_casting
function helpers:check_interrupt_needed(local_player, target)
    if not local_player or not target then
        return false, false
    end

    local ok_valid, is_valid = pcall(function()
        return target:is_valid()
    end)
    if not ok_valid or is_valid ~= true then
        return false, false
    end

    -- Check if CC toggle is active
    if not self:is_cc_toggle_active() then
        return false, false
    end

    -- Check if target is casting
    local ok_casting, is_casting = pcall(function()
        return target:is_casting_spell()
    end)
    if not ok_casting or not is_casting then
        return false, false
    end

    -- Check if cast is interruptable
    local ok_intr, is_interruptable = pcall(function()
        return target:is_active_spell_interruptable()
    end)
    if not ok_intr or not is_interruptable then
        return false, true -- Casting but not interruptable
    end

    return true, true
end

---@param local_player game_object
---@param target game_object
---@return boolean interrupted
function helpers:try_interrupt_cast(local_player, target)
    local should_interrupt = self:check_interrupt_needed(local_player, target)

    if not should_interrupt then
        pending_kick_pct = 0.0
        pending_kick_target_guid = nil
        pending_gouge_pct = 0.0
        pending_gouge_target_guid = nil
        return false
    end

    local current_guid = safe_get_guid(target)
    if not current_guid then
        pending_kick_pct = 0.0
        pending_kick_target_guid = nil
        pending_gouge_pct = 0.0
        pending_gouge_target_guid = nil
        return false
    end

    -- If our pending target no longer matches the current target, clear pending state.
    if pending_kick_target_guid and pending_kick_target_guid ~= current_guid then
        pending_kick_pct = 0.0
        pending_kick_target_guid = nil
    end
    if pending_gouge_target_guid and pending_gouge_target_guid ~= current_guid then
        pending_gouge_pct = 0.0
        pending_gouge_target_guid = nil
    end

    -- Get cast progress percentage (0-100)
    local cast_pct = 0
    local cast_duration_ms = 0
    pcall(function()
        cast_pct = target:get_cast_pct() or 0
        cast_duration_ms = target:get_cast_duration_ms() or 0
    end)

    local energy = local_player:get_power(enums.power_type.ENERGY)
    local kick = spell_data.cc.kick
    local gouge = spell_data.cc.gouge

    -- Find highest LEARNED rank for kick
    local kick_spell_id = nil
    if kick and kick.ids then
        for i = #kick.ids, 1, -1 do  -- Loop from highest to lowest rank
            local spell_id = kick.ids[i]
            -- Check if spell is learned (skip all other checks)
            local is_learned = spell_helper:is_spell_castable(
                spell_id,
                local_player,
                target,
                true,  -- skip_facing
                true,  -- skip_range
                true,  -- skip_usable (ignore energy/cooldown)
                true,  -- skip_controller
                false  -- skip_learned = FALSE → checks if learned!
            )
            if is_learned then
                kick_spell_id = spell_id
                break  -- Found highest learned rank
            end
        end
    end

    -- Find highest LEARNED rank for gouge
    local gouge_spell_id = nil
    if gouge and gouge.ids then
        for i = #gouge.ids, 1, -1 do
            local spell_id = gouge.ids[i]
            local is_learned = spell_helper:is_spell_castable(
                spell_id,
                local_player,
                target,
                true,  -- skip_facing
                true,  -- skip_range
                true,  -- skip_usable
                true,  -- skip_controller
                false  -- skip_learned = FALSE
            )
            if is_learned then
                gouge_spell_id = spell_id
                break
            end
        end
    end

    local kick_ready = kick_spell_id and not spell_helper:is_spell_on_cooldown(kick_spell_id)
    local gouge_ready = gouge_spell_id and not spell_helper:is_spell_on_cooldown(gouge_spell_id)

    -- PvP: Avoid wasting Gouge (Incapacitate DR/Immunity) when used as an interrupt fallback.
    if gouge_ready and self.is_pvp_mode_active and self:is_pvp_mode_active() and pvp_utiltiy and pvp_utiltiy.is_player and pvp_utiltiy.get_unit_dr and pvp_utiltiy.is_cc_immune and pvp_utiltiy.cc_flags and pvp_utiltiy.cc_flags.INCAPACITATE then
        local ok_player, is_player = pcall(function()
            return pvp_utiltiy:is_player(target)
        end)
        if ok_player and is_player == true then
            local min_mult = 0.5
            if menu_elements and menu_elements.pvp_cc_min_dr and menu_elements.pvp_cc_min_dr.get then
                local v = menu_elements.pvp_cc_min_dr:get()
                if v == 1 then
                    min_mult = 1.0
                elseif v == 2 then
                    min_mult = 0.5
                else
                    min_mult = 0.0
                end
            end

            if min_mult > 0 then
                local now = core.time()
                local ok_dr, mult = pcall(function()
                    return pvp_utiltiy:get_unit_dr(target, pvp_utiltiy.cc_flags.INCAPACITATE, now)
                end)
                if ok_dr and type(mult) == "number" and mult < min_mult then
                    gouge_ready = false
                end
            end

            if gouge_ready then
                local ok_imm, immune = pcall(function()
                    return pvp_utiltiy:is_cc_immune(target, pvp_utiltiy.cc_flags.INCAPACITATE, 200)
                end)
                if ok_imm and immune == true then
                    gouge_ready = false
                end
            end
        end
    end

    -- Priority 1: Execute scheduled kick if cast progress reached target %
    if pending_kick_target_guid == current_guid and pending_kick_pct > 0.0 then
        -- Check if we have enough energy to execute
        if energy < 25 then
            -- Still pooling energy, pause rotation
            return true
        end

        if cast_pct < pending_kick_pct then
            -- Cast hasn't reached our target % yet, keep waiting
            return true
        end

        -- Both conditions satisfied: energy >= 25 AND cast_pct >= pending_kick_pct
        if self:try_cast_cc(local_player, target, "kick") then
            pending_kick_pct = 0.0
            pending_kick_target_guid = nil
            return true
        end

        -- Kick failed (out of range, etc.), clear and reschedule
        pending_kick_pct = 0.0
        pending_kick_target_guid = nil
    end

    -- Priority 2: Schedule kick with randomized percentage delay and energy pooling
    if kick_ready and kick_spell_id then
        local min_pct, max_pct = get_kick_delay_pct_range(menu_elements)

        -- Fast cast safety: <500ms = instant kick
        if cast_duration_ms > 0 and cast_duration_ms < 500 then
            if self:try_cast_cc(local_player, target, "kick") then
                return true
            end
        end

        -- Instant kick if already exceeded max threshold
        if cast_pct >= max_pct then
            if self:try_cast_cc(local_player, target, "kick") then
                return true
            end
        end

        -- Schedule with energy pooling
        if energy < 25 then
            local energy_deficit = 25 - energy
            local regen_rate = 20
            if self:has_buff(local_player, "adrenaline_rush") then
                regen_rate = 40
            end

            local time_needed = energy_deficit / regen_rate

            if cast_duration_ms > 0 then
                local cast_duration_sec = cast_duration_ms / 1000
                local pct_per_sec = 100 / cast_duration_sec
                local pct_gain_during_pool = pct_per_sec * time_needed
                local pct_when_ready = cast_pct + pct_gain_during_pool

                if pct_when_ready < max_pct then
                    -- Schedule for randomized %
                    local target_pct = min_pct + (math.random() * (max_pct - min_pct))
                    pending_kick_pct = target_pct
                    pending_kick_target_guid = current_guid
                    return true  -- Pool energy
                end
                -- Energy won't be ready in time, fall through to gouge
            end
        else
            -- Have energy, schedule for randomized %
            local target_pct = min_pct + (math.random() * (max_pct - min_pct))
            pending_kick_pct = target_pct
            pending_kick_target_guid = current_guid
            return true
        end
    end

    -- Priority 3: Execute scheduled gouge if cast progress reached target %
    if pending_gouge_target_guid == current_guid and pending_gouge_pct > 0.0 then
        if energy < 45 then
            return true  -- Still pooling
        end

        if cast_pct < pending_gouge_pct then
            return true  -- Wait for %
        end

        if self:try_cast_cc(local_player, target, "gouge") then
            pending_gouge_pct = 0.0
            pending_gouge_target_guid = nil
            return true
        end

        pending_gouge_pct = 0.0
        pending_gouge_target_guid = nil
    end

	    -- Priority 4: Schedule gouge with energy pooling
	    if gouge_ready and gouge_spell_id then
        local min_pct, max_pct = get_kick_delay_pct_range(menu_elements)

        -- Fast cast safety
        if cast_duration_ms > 0 and cast_duration_ms < 500 then
            if self:try_cast_cc(local_player, target, "gouge") then
                return true
            end
            return false
        end

        -- Instant gouge if exceeded max
        if cast_pct >= max_pct then
            if self:try_cast_cc(local_player, target, "gouge") then
                return true
            end
            return false
        end

        -- Schedule with energy pooling
        if energy < 45 then
            local energy_deficit = 45 - energy
            local regen_rate = 20
            if self:has_buff(local_player, "adrenaline_rush") then
                regen_rate = 40
            end

            local time_needed = energy_deficit / regen_rate

            if cast_duration_ms > 0 then
                local cast_duration_sec = cast_duration_ms / 1000
                local pct_per_sec = 100 / cast_duration_sec
                local pct_gain_during_pool = pct_per_sec * time_needed
                local pct_when_ready = cast_pct + pct_gain_during_pool

                if pct_when_ready < max_pct then
                    local target_pct = min_pct + (math.random() * (max_pct - min_pct))
                    pending_gouge_pct = target_pct
                    pending_gouge_target_guid = current_guid
                    return true  -- Pool energy
                end
                return false  -- Won't be ready in time
            end
        else
            -- Have energy, schedule
            local target_pct = min_pct + (math.random() * (max_pct - min_pct))
            pending_gouge_pct = target_pct
            pending_gouge_target_guid = current_guid
            return true
        end
	    end

	    -- Priority 5: Arcane Torrent (Blood Elf) fallback interrupt (AoE silence, melee range).
	    if menu_elements and menu_elements.use_arcane_torrent_interrupt and menu_elements.use_arcane_torrent_interrupt.get_state
	        and menu_elements.use_arcane_torrent_interrupt:get_state() == true then
	        local ok_learned, learned = pcall(function()
	            return core.spell_book.is_spell_learned(28730) or core.spell_book.is_spell_learned(25046)
	        end)
	        if ok_learned and learned == true then
	            local threshold = (menu_elements.arcane_torrent_interrupt_pct and menu_elements.arcane_torrent_interrupt_pct.get and menu_elements.arcane_torrent_interrupt_pct:get()) or 25
	            if cast_pct >= threshold then
	                local dist_ok = false
	                pcall(function()
	                    dist_ok = target:distance() <= 8.0
	                end)
	                if dist_ok then
	                    if try_cast_spell_generic(spell_data.racials, "arcane_torrent", local_player, nil, {
	                            throttle_time = 0.2,
	                            queue_priority = 3,
	                            skip_facing = true,
	                            skip_range = true,
	                            skip_learned = true
	                        }) then
	                        return true
	                    end
	                end
	            end
	        end
	    end

	    return false  -- No interrupt possible
	end

---@param local_player game_object
---@param max_range number|nil
---@param half_angle_rad number|nil
---@return boolean
function helpers:try_interrupt_nearby(local_player, max_range, half_angle_rad)
    if not local_player then
        return false
    end

    if not self:is_cc_toggle_active() then
        return false
    end

    local player_pos = local_player:get_position()
    if not player_pos then
        return false
    end

    local range = max_range or 5
    local enemies = unit_helper:get_enemy_list_around(player_pos, range, true, false, false, false)
    if not enemies or #enemies == 0 then
        return false
    end

    local best_target = nil
    local best_time_left = nil

    -- OPTIMIZATION: Reduced API calls per enemy, early exits, cached position
    for _, enemy in __object_safety.live_ipairs(enemies) do
        -- OPTIMIZATION 1: Single validity check (combines is_valid + is_dead)
        if not enemy or not enemy:is_valid() or enemy:is_dead() then
            goto continue
        end

        -- OPTIMIZATION 2: Cache position (used multiple times)
        local enemy_pos = enemy:get_position()
        if not enemy_pos then
            goto continue
        end

        -- OPTIMIZATION 3: Distance check BEFORE expensive API calls
        local distance = enemy_pos:dist_to_ignore_z(player_pos)
        if distance > range then
            goto continue
        end

        -- OPTIMIZATION 4: Arc check before friend/attack checks
        if not self:is_in_front_arc(local_player, enemy, half_angle_rad) then
            goto continue
        end

        -- OPTIMIZATION 5: Combined friend/can_attack check (removed pcall overhead)
        if enemy:is_friend_with(local_player) or not local_player:can_attack(enemy) then
            goto continue
        end

        -- OPTIMIZATION 6: Early exit if not casting (most common case)
        if not enemy:is_casting_spell() then
            goto continue
        end

        -- Only check interruptable if casting
        if enemy:is_active_spell_interruptable() then
            local cast_end = enemy:get_active_spell_cast_end_time()
            local time_left = cast_end > 0 and (cast_end - core.time()) or 0
            if time_left < 0 then
                time_left = 0
            end

            if not best_time_left or time_left < best_time_left then
                best_target = enemy
                best_time_left = time_left
            end
        end

        ::continue::
    end

    if not best_target then
        return false
    end

    -- Get cast information for delay calculations
    local cast_pct = best_target:get_cast_pct() or 0
    local cast_duration_ms = best_target:get_cast_duration_ms() or 0

    local energy = local_player:get_power(enums.power_type.ENERGY)
    local kick = spell_data.cc.kick
    local gouge = spell_data.cc.gouge

    -- Find highest LEARNED rank for kick (same logic as single-target interrupt)
    local kick_spell_id = nil
    if kick and kick.ids then
        for i = #kick.ids, 1, -1 do  -- Loop from highest to lowest rank
            local spell_id = kick.ids[i]
            -- Check if spell is learned (skip all other checks)
            local is_learned = spell_helper:is_spell_castable(
                spell_id,
                local_player,
                best_target,
                true,  -- skip_facing
                true,  -- skip_range
                true,  -- skip_usable (ignore energy/cooldown)
                true,  -- skip_controller
                false  -- skip_learned = FALSE → checks if learned!
            )
            if is_learned then
                kick_spell_id = spell_id
                break  -- Found highest learned rank
            end
        end
    end

    -- Find highest LEARNED rank for gouge
    local gouge_spell_id = nil
    if gouge and gouge.ids then
        for i = #gouge.ids, 1, -1 do
            local spell_id = gouge.ids[i]
            local is_learned = spell_helper:is_spell_castable(
                spell_id,
                local_player,
                best_target,
                true,  -- skip_facing
                true,  -- skip_range
                true,  -- skip_usable (ignore energy/cooldown)
                true,  -- skip_controller
                false  -- skip_learned = FALSE → checks if learned!
            )
            if is_learned then
                gouge_spell_id = spell_id
                break
            end
        end
    end

    local kick_ready = kick_spell_id and not spell_helper:is_spell_on_cooldown(kick_spell_id)
    local gouge_ready = gouge_spell_id and not spell_helper:is_spell_on_cooldown(gouge_spell_id)

    -- PvP: Avoid wasting Gouge (Incapacitate DR/Immunity) when used as an interrupt fallback.
    if gouge_ready and self.is_pvp_mode_active and self:is_pvp_mode_active() and pvp_utiltiy and pvp_utiltiy.is_player and pvp_utiltiy.get_unit_dr and pvp_utiltiy.is_cc_immune and pvp_utiltiy.cc_flags and pvp_utiltiy.cc_flags.INCAPACITATE then
        local ok_player, is_player = pcall(function()
            return pvp_utiltiy:is_player(best_target)
        end)
        if ok_player and is_player == true then
            local min_mult = 0.5
            if menu_elements and menu_elements.pvp_cc_min_dr and menu_elements.pvp_cc_min_dr.get then
                local v = menu_elements.pvp_cc_min_dr:get()
                if v == 1 then
                    min_mult = 1.0
                elseif v == 2 then
                    min_mult = 0.5
                else
                    min_mult = 0.0
                end
            end

            if min_mult > 0 then
                local now = core.time()
                local ok_dr, mult = pcall(function()
                    return pvp_utiltiy:get_unit_dr(best_target, pvp_utiltiy.cc_flags.INCAPACITATE, now)
                end)
                if ok_dr and type(mult) == "number" and mult < min_mult then
                    gouge_ready = false
                end
            end

            if gouge_ready then
                local ok_imm, immune = pcall(function()
                    return pvp_utiltiy:is_cc_immune(best_target, pvp_utiltiy.cc_flags.INCAPACITATE, 200)
                end)
                if ok_imm and immune == true then
                    gouge_ready = false
                end
            end
        end
    end

    local best_guid = safe_get_guid(best_target)
    if not best_guid then
        pending_nearby_kick_pct = 0.0
        pending_nearby_kick_target_guid = nil
        return false
    end

    -- Clear pending if it no longer matches our current best target.
    if pending_nearby_kick_target_guid and pending_nearby_kick_target_guid ~= best_guid then
        pending_nearby_kick_pct = 0.0
        pending_nearby_kick_target_guid = nil
    end

    -- Priority 1: Execute pending nearby kick if conditions met
    if pending_nearby_kick_target_guid == best_guid and pending_nearby_kick_pct > 0.0 then
        if kick_ready and energy >= 25 then
            if cast_pct >= pending_nearby_kick_pct then
                if self:try_cast_cc(local_player, best_target, "kick") then
                    pending_nearby_kick_pct = 0.0
                    pending_nearby_kick_target_guid = nil
                    return true
                end
            else
                return true  -- Wait for target %
            end
        end
        -- Clear stale pending if kick not ready anymore
        pending_nearby_kick_pct = 0.0
        pending_nearby_kick_target_guid = nil
    end

    -- Priority 2: Schedule new nearby kick with delay
    if kick_ready and kick_spell_id then
        local min_pct, max_pct = get_kick_delay_pct_range(menu_elements)

        -- Fast cast safety: <500ms = instant kick
        if cast_duration_ms > 0 and cast_duration_ms < 500 then
            if self:try_cast_cc(local_player, best_target, "kick") then
                return true
            end
        end

        -- Instant kick if already exceeded max threshold
        if cast_pct >= max_pct then
            if self:try_cast_cc(local_player, best_target, "kick") then
                return true
            end
        end

        -- Schedule with energy pooling
        if energy < 25 then
            local energy_deficit = 25 - energy
            local regen_rate = 20
            if self:has_buff(local_player, "adrenaline_rush") then
                regen_rate = 40
            end

            local time_needed = energy_deficit / regen_rate

            if cast_duration_ms > 0 then
                local cast_duration_sec = cast_duration_ms / 1000
                local pct_per_sec = 100 / cast_duration_sec
                local pct_gain_during_pool = pct_per_sec * time_needed
                local pct_when_ready = cast_pct + pct_gain_during_pool

                if pct_when_ready < max_pct then
                    -- Schedule for randomized %
                    local target_pct = min_pct + (math.random() * (max_pct - min_pct))
                    pending_nearby_kick_pct = target_pct
                    pending_nearby_kick_target_guid = best_guid
                    return true  -- Pool energy
                end
                -- Energy won't be ready in time, fall through to gouge
            end
        else
            -- Have energy, schedule for randomized %
            local target_pct = min_pct + (math.random() * (max_pct - min_pct))
            pending_nearby_kick_pct = target_pct
            pending_nearby_kick_target_guid = best_guid
            return true
        end
    end

    -- Priority 3: Gouge fallback (instant, no scheduling for simplicity)
    if gouge_ready and gouge_spell_id then
        if energy >= 45 then
            if self:try_cast_cc(local_player, best_target, "gouge") then
                return true
            end
        else
            -- Pool energy for gouge
            local regen_rate = 20
            if self:has_buff(local_player, "adrenaline_rush") then
                regen_rate = 40
            end
            local time_needed = (45 - energy) / regen_rate
            if best_time_left and best_time_left > (time_needed + 0.05) then
                return true
            end
        end
    end

    return false
end

---@param local_player game_object
---@param target game_object
---@param energy number
---@param cp number
---@param player_hp_pct number Player HP percentage (optional, for emergency Gouge)
---@return boolean should_gouge
---@return boolean should_pause_rotation
---@return boolean should_bandage
function helpers:try_gouge_energy_regen(local_player, target, energy, cp, player_hp_pct)
    player_hp_pct = player_hp_pct or 100
    debug_print("gouge_energy.called", "[DBG] CP_GER called")

    if not local_player or not target then
        debug_print("gouge_energy.fail_no_player_or_target", "[DBG] CP_GER abort (missing unit)")
        return false, false, false
    end

    -- Check if EMERGENCY Gouge (low HP, takes priority)
    -- Get threshold from UI (default 40 if not set)
    local emergency_threshold = menu_elements.auto_bandage_threshold and menu_elements.auto_bandage_threshold:get() or 40
    local is_emergency = player_hp_pct <= emergency_threshold

    -- Check if Gouge Energy Regen toggle is active (skip for emergency)
    if not is_emergency and not self:is_gouge_energy_regen_toggle_active() then
        debug_print("gouge_energy.fail_toggle_off", "[DBG] CP_GER abort (toggle off)")
        return false, false, false
    end

    -- Check if CC toggle is active (skip for emergency - always allow emergency Gouge+Bandage)
    if not is_emergency and not self:is_cc_toggle_active() then
        debug_print("gouge_energy.fail_cc_toggle_off", "[DBG] CP_GER abort (cc toggle off)")
        return false, false, false
    end

    -- Check if in party/raid with nearby members
    local ok_party, is_in_party = pcall(function()
        return local_player:is_in_party()
    end)

    local ok_raid, is_in_raid = pcall(function()
        return local_player:is_in_raid()
    end)

    -- Check if party members are within 40 yards (affects Gouge behavior)
    local has_nearby_party_members = false
    if ok_party and is_in_party then
        local party_members = local_player:get_party_members_in_range(40, true)
        has_nearby_party_members = party_members and #party_members > 0
    end
    if ok_raid and is_in_raid then
        has_nearby_party_members = true  -- In raid, always treat as having nearby members
    end

    -- Solo vs Group behavior:
    -- Solo: Can use Gouge for HP emergency OR energy regen
    -- Group (nearby members): Skip HP/energy Gouge (rely on party heals)
    if has_nearby_party_members then
        if is_emergency then
            debug_print("gouge_emergency.fail_in_group", "[DBG] CP_GER abort (group)")
            return false, false, false
        else
            debug_print("gouge_energy.fail_in_group", "[DBG] CP_GER abort (group)")
            return false, false, false
        end
    end

    local current_time = core.time()

    -- Check if we recently attempted Gouge
    if gouge_energy_regen_time > 0 then
        local time_since_attempt = current_time - gouge_energy_regen_time

        -- Still within tracking window and targeting same enemy
        if gouge_energy_regen_target and (__object_safety.same(gouge_energy_regen_target,target)) then
            -- Check if debuff is active (Gouge landed successfully)
            if is_gouge_debuff_active(target) then
                debug_print("gouge_energy.target_still_gouged", "[DBG] CP_GER hold (state active)")
                return false, true, false -- Still gouged, pause rotation, no new bandage
            end

            -- Debuff not active - check if we should timeout
            if time_since_attempt < GOUGE_DEBUFF_CHECK_TIMEOUT then
                -- Still within debuff check window, keep waiting
                debug_print("gouge_energy.waiting_for_debuff", "[DBG] CP_GER hold (await confirm)")
                return false, true, false
            else
                -- Timeout exceeded - Gouge missed/resisted, reset and continue rotation
                debug_print("gouge_energy.timeout", "[DBG] CP_GER reset (timeout)")
                gouge_energy_regen_target = nil
                gouge_energy_regen_time = 0
                return false, false, false
            end
        end

        -- Different target or timeout - check retry cooldown
        if time_since_attempt < GOUGE_RETRY_COOLDOWN then
            -- Don't spam Gouge attempts
            debug_print("gouge_energy.fail_retry_cooldown", "[DBG] CP_GER abort (retry cd)")
            return false, false, false
        end
    end

    debug_print("gouge_energy.passed_checks", "[DBG] CP_GER pass (checks)")

    -- Check if in combat (Gouge + Bandage only in combat - out of combat use food instead)
    local in_combat = unit_helper:is_in_combat(local_player)
    if not in_combat then
        debug_print("gouge_energy.fail_not_in_combat", "[DBG] CP_GER abort (not in combat)")
        return false, false, false
    end

    -- PRIORITY 1: EMERGENCY Gouge (low HP, solo only)
    if is_emergency and cp < 5 then
        -- Check 1: Recently Bandaged debuff (60s cooldown) - no point gouging if can't bandage
        if local_player:debuff_up({11196}) then
            debug_print("gouge_emergency.fail_recently_bandaged", "[DBG] CP_GER abort (recent lockout)")
            return false, false, false
        end

        -- Check 2: Energy pooling (Gouge costs 45 energy)
        if energy < 45 then
            debug_print("gouge_emergency.pooling_energy", "[DBG] CP_GER hold (pool resource)")
            return false, true, false  -- No cast, PAUSE rotation (pool energy), no bandage
        end

        debug_print("gouge_emergency.attempting", "[DBG] CP_GER attempt (emergency)")

        -- Safety check: Don't Gouge if other enemies are targeting us
        if self:has_other_enemy_targeting_player(local_player, target, 40) then
            debug_print("gouge_emergency.fail_other_enemies", "[DBG] CP_GER abort (safety)")
            return false, false, false
        end

        -- Facing check: Gouge requires frontal position (not behind target)
        if self:is_behind_target(local_player, target) then
            debug_print("gouge_emergency.fail_behind_target", "[DBG] CP_GER abort (position)")
            return false, false, false
        end

        -- Try to cast Gouge
        local gouge_cast = self:try_cast_cc(local_player, target, "gouge")

        if gouge_cast then
            gouge_energy_regen_time = current_time
            gouge_energy_regen_target = target
            gouge_should_bandage = true  -- Mark that we should bandage during this Gouge
            log_throttled("gouge.emergency.cast", 2.0, "[CP] ACTION (emergency)")
            return true, true, true  -- Gouge cast, pause rotation, USE BANDAGE
        else
            debug_print("gouge_emergency.fail_cast", "[DBG] CP_GER fail (cast)")
            return false, false, false
        end
    end

    -- PRIORITY 2: Energy Regen Gouge (existing logic, solo only)
    -- Only gouge for energy regen if:
    -- 1. Energy is capping (>= 80)
    -- 2. We have already generated 2-4 CP (established combat momentum)
    -- 3. Not at 5 CP (don't waste time when we can finisher)
    -- 4. Target has enough HP left (> 30%, not worth on low HP targets)
    -- 5. Not in emergency (handled above)
    if energy >= 80 and cp >= 2 and cp < 5 then
        -- Target HP check: Don't waste Gouge on low HP targets (they die too fast)
        local target_hp_pct = target:get_health_percentage()
        if target_hp_pct <= 30 then
            debug_print("gouge_energy.fail_target_hp_low", "[DBG] CP_GER abort (target low)")
            return false, false, false
        end

        debug_print("gouge_energy.conditions_met", "[DBG] CP_GER attempt")

        -- Facing check: Gouge requires frontal position (not behind target)
        if self:is_behind_target(local_player, target) then
            debug_print("gouge_energy.fail_behind_target", "[DBG] CP_GER abort (position)")
            return false, false, false
        end

        -- DEBUG: Try to cast gouge and check why it failed
        local gouge_cast = self:try_cast_cc(local_player, target, "gouge")

        if gouge_cast then
            gouge_energy_regen_time = current_time
            gouge_energy_regen_target = target
            gouge_should_bandage = false  -- NO bandage for energy regen Gouge
            log_throttled("gouge.energy.cast", 2.0, "[CP] ACTION (regen)")
            return true, true, false -- Gouge cast, pause rotation, NO BANDAGE (energy regen only)
        else
            -- Gouge failed - log why
            local spell_data_module = require("rotations/rogue/tbc/spell_data")
            local gouge_spell = spell_data_module.cc.gouge
            if gouge_spell and gouge_spell.ids then
                local spell_id = gouge_spell.ids[#gouge_spell.ids]

                ---@type spell_helper
                local spell_helper_module = require("common/utility/spell_helper")

                local is_on_cd = spell_helper_module:is_spell_on_cooldown(spell_id)

                if is_on_cd then
                    log_throttled("gouge.energy.fail", 2.0, "[CP] ACTION FAIL (cooldown)")
                elseif energy < 45 then
                    log_throttled("gouge.energy.fail", 2.0, "[CP] ACTION FAIL (resource)")
                else
                    log_throttled("gouge.energy.fail", 2.0, "[CP] ACTION FAIL (unknown)")
                end
            end
        end
    else
        debug_print("gouge_energy.fail_conditions", "[DBG] CP_GER abort (conditions)")
    end

    return false, false, false
end

---@return boolean should_pause
function helpers:is_gouge_energy_regen_active()
    if not gouge_energy_regen_target or gouge_energy_regen_time == 0 then
        return false
    end

    local current_time = core.time()
    local time_since_attempt = current_time - gouge_energy_regen_time

    -- Check if debuff is active (Gouge landed successfully)
    if is_gouge_debuff_active(gouge_energy_regen_target) then
        return true
    end

    -- Debuff not active - check timeout
    if time_since_attempt < GOUGE_DEBUFF_CHECK_TIMEOUT then
        -- Still within check window, keep waiting
        return true
    end

    -- Timeout exceeded or debuff broke - reset and continue rotation
    gouge_energy_regen_target = nil
    gouge_energy_regen_time = 0
    gouge_should_bandage = false  -- Reset bandage flag
    return false
end

--- Check if we should attempt to bandage during current Gouge
---@return boolean should_bandage
function helpers:should_bandage_during_gouge()
    return gouge_should_bandage
end

-- ============================================================================
-- GOUGE + BANDAGE EMERGENCY HEALING
-- ============================================================================

--- Check if any enemy within range is targeting the player
--- Used to determine if it's safe to Gouge + Bandage
---@param local_player game_object
---@param current_target game_object The target we plan to Gouge
---@param range number Range in yards (default: 40)
---@return boolean has_aggro True if another enemy is targeting player
function helpers:has_other_enemy_targeting_player(local_player, current_target, range)
    if not local_player or not current_target then
        return true  -- Safe default: assume aggro
    end

    range = range or 40
    local player_pos = local_player:get_position()
    if not player_pos then
        return true
    end

    -- Get all enemies within range
    local enemies = local_player:get_enemies_in_range(range, false)
    if not enemies then
        return false
    end

    -- Check if any enemy (other than current target) is targeting player
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and (not __object_safety.same(enemy,current_target)) and enemy:is_valid() and enemy:is_alive() then
            -- Check if this enemy is targeting the player
            local enemy_target = enemy:get_target()
            if enemy_target and (__object_safety.same(enemy_target,local_player)) then
                return true  -- Another enemy is targeting us!
            end
        end
    end

    return false  -- Safe to Gouge + Bandage
end

-- ============================================================================
-- ADVANCED TALENT ABILITIES
-- ============================================================================

--- Attempts to cast Expose Armor (armor reduction finisher for Elite/Boss fights).
--- Only casts at 5 CP on Elite/Boss targets.
--- Checks if Expose Armor or Sunder Armor is already active.
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @param cp number Current combo points
--- @return boolean true if Expose Armor was queued successfully
function helpers:try_cast_expose_armor(local_player, target, cp)
    return try_cast_spell_generic(spell_data.finishers, "expose_armor", local_player, target, {
        throttle_time = 0,
        queue_priority = 2,
        extra_checks_func = function(_lp, tgt, spell_info)
            -- Raid policy: Expose Armor is typically assigned; avoid overwriting sunder slots.
            if menu_elements and menu_elements.raid_mode and menu_elements.raid_mode:get_state() == true then
                local policy = (menu_elements.raid_expose_armor_policy and menu_elements.raid_expose_armor_policy.get and menu_elements.raid_expose_armor_policy:get()) or 1
                if policy == 2 then
                    return false -- Never
                end
                if policy ~= 3 then
                    -- Auto: falls through to normal toggle check
                end
            end

            -- Check menu toggle
            do
                local allow = false
                if menu_elements and menu_elements.raid_mode and menu_elements.raid_mode:get_state() == true then
                    local policy = (menu_elements.raid_expose_armor_policy and menu_elements.raid_expose_armor_policy.get and menu_elements.raid_expose_armor_policy:get()) or 1
                    if policy == 3 then
                        allow = true -- Assigned
                    end
                end
                if not allow then
                    if not menu_elements or not menu_elements.auto_expose_armor_enabled or not menu_elements.auto_expose_armor_enabled:get_state() then
                        return false
                    end
                end
            end

            -- Only at optimal CP (5 CP)
            if cp < spell_info.cp_required_optimal then
                return false
            end

            -- Don't reapply if Expose Armor or Sunder Armor is active
            local has_expose = has_debuff_ids(tgt, {8647, 8649, 8650, 11197, 11198})
            local has_sunder = has_debuff_ids(tgt, {7386, 7405, 8380, 11596, 11597})
            if has_expose or has_sunder then
                return false
            end

            -- Only on Elite/Boss
            local classification = tgt:get_classification()
            return classification >= enums.classification.ELITE
        end
    })
end

--- Attempts to cast Rupture (DoT finisher for Elite/Boss fights).
--- Cast policy is controlled via the PvE Rupture menu settings (defaults: 5 CP, Elite/Boss only).
--- Checks if Rupture debuff is already active.
---
--- @param local_player game_object Player character
--- @param target game_object Current target
--- @param cp number Current combo points
--- @return boolean true if Rupture was queued successfully
function helpers:try_cast_rupture(local_player, target, cp)
    return try_cast_spell_generic(spell_data.finishers, "rupture", local_player, target, {
        throttle_time = 0,
        queue_priority = 2,
        extra_checks_func = function(_lp, tgt, spell_info)
            -- Allow configurable CP threshold (defaults to optimal = 5 CP)
            local min_cp = spell_info.cp_required_optimal or 5
            if menu_elements and menu_elements.pve_rupture_min_cp and menu_elements.pve_rupture_min_cp.get then
                local ok, v = pcall(function()
                    return menu_elements.pve_rupture_min_cp:get()
                end)
                if ok and type(v) == "number" then
                    min_cp = v
                end
            end
            if spell_info.cp_required_min then
                min_cp = math.max(min_cp, spell_info.cp_required_min)
            end
            if min_cp > 5 then
                min_cp = 5
            end
            if cp < min_cp then
                return false
            end

            -- Don't reapply if already active
            if has_debuff_ids(tgt, spell_info.ids) then
                return false
            end

            -- 1 = Elite/Boss Only, 2 = TTD-Based (Any Target)
            local policy = 1
            if menu_elements and menu_elements.pve_rupture_target_policy and menu_elements.pve_rupture_target_policy.get then
                local ok, v = pcall(function()
                    return menu_elements.pve_rupture_target_policy:get()
                end)
                if ok and type(v) == "number" then
                    policy = v
                end
            end

            if policy == 1 then
                local classification = tgt:get_classification()
                if classification < enums.classification.ELITE then
                    return false
                end
            end

            return true
        end
    })
end

--- Attempts to cast Preparation (Subtlety talent - resets Vanish, Evasion, Sprint, Cold Blood).
--- Only casts when at least 2 major cooldowns are currently on cooldown.
--- Requires cooldowns toggle to be enabled.
---
--- @param local_player game_object Player character
--- @return boolean true if Preparation was queued successfully
function helpers:try_cast_preparation(local_player)
    if not local_player then
        return false
    end

    -- Check menu toggle
    if not menu_elements or not menu_elements.auto_preparation_enabled then
        return false
    end

    if not menu_elements.auto_preparation_enabled:get_state() then
        return false
    end

    -- Requires cooldowns toggle
    if not self:is_cooldowns_toggle_active() then
        return false
    end

    -- Check if Preparation is learned and not on cooldown
    if not self:is_cooldown_ready("preparation") then
        return false
    end

    -- SMART LOGIC: Only use if resetting valuable CDs
    -- Preparation resets: Vanish, Sprint, Evasion, Cold Blood, Shadowstep

    local cooldowns_on_cd = 0

    -- Check Vanish (5 min CD - highest value)
    if spell_helper:is_spell_on_cooldown(1856) then
        cooldowns_on_cd = cooldowns_on_cd + 1
    end

    -- Check Evasion (5 min CD - defensive value)
    if spell_helper:is_spell_on_cooldown(5277) then
        cooldowns_on_cd = cooldowns_on_cd + 1
    end

    -- Check Cold Blood (5 min CD - DPS value)
    local cb = spell_data.cooldowns.cold_blood
    if cb and spell_helper:is_spell_on_cooldown(cb.ids[1]) then
        cooldowns_on_cd = cooldowns_on_cd + 1
    end

    -- Only use if at least 2 major CDs are down (prevents waste)
    if cooldowns_on_cd < 2 then
        return false
    end

    -- Cast Preparation using generic spell pattern
    return try_cast_spell_generic(spell_data.cooldowns, "preparation", local_player, nil, {
        throttle_time = 0,
        queue_priority = 2, -- Same as other cooldowns
        skip_facing = true,
        skip_range = true
    })
end

-- ============================================================================
-- PVP ARENA HELPERS (Stealth, CP dump, DoT checks)
-- ============================================================================

--- Returns the highest learned Stealth spell ID (1784-1787), or nil if none learned.
---@param local_player game_object
---@return number|nil
function helpers:get_highest_stealth_rank(local_player)
    if not local_player then return nil end

    local stealth_ids = spell_data.buffs.stealth or {1784, 1785, 1786, 1787}

    for i = #stealth_ids, 1, -1 do
        local spell_id = stealth_ids[i]
        local ok, is_learned = pcall(function()
            return spell_helper:is_spell_castable(
                spell_id, local_player, local_player,
                true,  -- skip_facing
                true,  -- skip_range
                true,  -- skip_usable
                true,  -- skip_controller
                false  -- skip_learned = FALSE (must be learned)
            )
        end)
        if ok and is_learned then
            return spell_id
        end
    end

    return nil
end

--- Checks if the player has any damage-over-time debuffs that would break Stealth.
---@param local_player game_object
---@return boolean
function helpers:has_stealth_breaking_debuffs(local_player)
    if not local_player or not spell_data.damage_over_time then
        return false
    end

    local dot_groups = {
        spell_data.damage_over_time.rogue_bleeds,
        spell_data.damage_over_time.warrior_bleeds,
        spell_data.damage_over_time.druid_bleeds,
        spell_data.damage_over_time.druid_dots,
        spell_data.damage_over_time.warlock_dots,
        spell_data.damage_over_time.hunter_dots,
        spell_data.damage_over_time.priest_dots,
        spell_data.damage_over_time.mage_dots,
        spell_data.damage_over_time.shaman_dots
    }

    for _, group in ipairs(dot_groups) do
        if type(group) == "table" then
            for _, dot_id in ipairs(group) do
                local ok, has_dot = pcall(function()
                    return local_player:debuff_up(dot_id) == true
                end)
                if ok and has_dot then
                    return true
                end
            end
        end
    end

    return false
end

--- Attempts to cast Stealth (not Vanish) when out of combat and safe to do so.
---@param local_player game_object
---@return boolean true if Stealth was queued
function helpers:try_cast_stealth(local_player)
    if not local_player then
        return false
    end

    -- Already stealthed
    if self:is_in_stealth(local_player) then
        return false
    end

    -- Must be out of combat
    local ok_combat, in_combat = pcall(function()
        return local_player:affecting_combat()
    end)
    if not ok_combat or in_combat then
        return false
    end

    -- No DoTs that would break stealth
    if self:has_stealth_breaking_debuffs(local_player) then
        return false
    end

    -- GCD check
    local gcd_remaining = safe_get_gcd_remains_ms(local_player)
    if gcd_remaining > 0 then
        return false
    end

    -- Not casting/channeling
    local ok_cast, is_casting = pcall(function()
        return local_player:is_channeling_or_casting()
    end)
    if ok_cast and is_casting then
        return false
    end

    local stealth_id = self:get_highest_stealth_rank(local_player)
    if not stealth_id then
        return false
    end

    local ok, castable = pcall(function()
        return spell_helper:is_spell_castable(
            stealth_id, local_player, local_player,
            true,   -- skip_facing
            true,   -- skip_range
            false,  -- skip_usable
            false,  -- skip_controller
            false   -- skip_learned
        )
    end)
    if not ok or not castable then
        return false
    end

    spell_queue:queue_spell_target(stealth_id, local_player, 11, "Stealth (Restealth)")
    return true  -- fire-and-forget: queue accepted if we reach this point
end

--- Dumps combo points before Blind for maximum value.
--- Priority: Rupture (anti-bandage) > SnD refresh > Eviscerate (damage).
---@param local_player game_object
---@param target game_object
---@return boolean true if a finisher was cast (caller should wait 1 frame)
function helpers:dump_combo_points_before_blind(local_player, target)
    if not local_player or not target then
        return false
    end

    local cp = self:get_combo_points(local_player) or 0
    if cp < 2 then
        return false
    end

    local energy = local_player:get_power(enums.power_type.ENERGY) or 0
    if energy < 25 then
        return false
    end

    -- Priority 1: Rupture (CP >= 3) - prevents enemy bandaging during our reset
    if cp >= 3 and energy >= 25 then
        local rupture_ids = spell_data.debuffs and spell_data.debuffs.rupture
        local rupture_active = false
        if rupture_ids then
            for _, id in ipairs(rupture_ids) do
                local ok, up = pcall(function() return target:debuff_up(id) == true end)
                if ok and up then
                    rupture_active = true
                    break
                end
            end
        end
        if not rupture_active then
            if self:try_cast_finisher(local_player, target, "rupture") then
                return true
            end
        end
    end

    -- Priority 2: SnD refresh (CP >= 2, SnD expiring within 3s)
    if cp >= 2 and energy >= 25 then
        local snd_remaining = self:get_buff_remaining(local_player, "slice_and_dice")
        if snd_remaining > 0 and snd_remaining <= 3000 then
            if self:try_cast_finisher(local_player, target, "slice_and_dice") then
                return true
            end
        end
    end

    -- Priority 3: Eviscerate (CP >= 4) - damage dump
    if cp >= 4 and energy >= 35 then
        if self:try_cast_finisher(local_player, target, "eviscerate") then
            return true
        end
    end

    return false
end

local consumables = require("rotations/rogue/tbc/helpers/consumables")
local automation = require("rotations/rogue/tbc/helpers/automation")
local racials = require("rotations/rogue/tbc/helpers/racials")

consumables.register(helpers)
automation.register(helpers)
racials.register(helpers)

return helpers

