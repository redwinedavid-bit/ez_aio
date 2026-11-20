local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Priest Rotation AIO (TBC Classic 2.4.3)
-- Holy/Discipline Healer + Shadow DPS fallback (solo/leveling)
-- ============================================================================
print("[AIO] Loading Priest Rotation Logic Fixes (v1.1)...")


local rotation_logic = {}

---@type enums
local enums = require("common/enums")

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

-- Import spells
local spells = require("rotations/priest/tbc/spells")

-- ============================================================================
-- STATE TRACKING & CACHING
-- ============================================================================

local GroupState = {
    members = {},
    lowest_ally = nil,
    lowest_hp = 100,
    tank = nil,
    tank_hp = 100,
    below_aoe_count = 0,
    below_coh_count = 0,
    dispel_magic = {},
    dispel_disease = {},
    last_dispel_refresh = 0,
    last_member_refresh = 0,
}

local last_buff_check = 0
local BUFF_CHECK_INTERVAL_MS = 1000

local last_dispel_check = 0
local DISPEL_CHECK_INTERVAL_MS = 500
local MEMBER_REFRESH_INTERVAL_MS = 1000

local last_heal_cast = 0
local HEAL_THROTTLE_MS = 100

local last_shield_cast = {}
local SHIELD_COOLDOWN_MS = 15000 -- Weakened Soul duration

local last_inner_focus_use = 0
local INNER_FOCUS_THROTTLE_MS = 1000

-- Cancel-casting throttle (avoid spamming cancel_spells every tick for the same cast)
local last_cancel_cast_start_time = -1
local last_cancel_spell_id = 0
local last_cancel_attempt_ms = 0

-- Direct single-target heal spell IDs (TBC) that should be eligible for strict cancel-casting.
-- Note: include all ranks so we can gate off active spell id without relying on spell name.
local DIRECT_HEAL_SPELL_IDS = {
    -- Greater Heal
    [25213] = true, [25210] = true, [25314] = true, [10965] = true, [10964] = true, [10963] = true, [2060] = true,
    -- Heal
    [6064] = true, [6063] = true, [2055] = true, [2054] = true,
    -- Flash Heal
    [25235] = true, [25233] = true, [10917] = true, [10916] = true, [10915] = true, [9474] = true,
    [9473] = true, [9472] = true, [2061] = true,
    -- Binding Heal
    [32546] = true,
}

-- Wand auto-attack state (ported from Warlock wand logic, simplified for Priest)
-- Wand debug logging
local _last_wand_debug_ms = 0

-- Vampiric Touch debounce (prevent double cast)
local last_vt_cast = 0

-- Wand state persistence
local last_wand_toggle_ms = 0
local WAND_TOGGLE_THROTTLE_MS = 500
local wand_auto_active = false
local last_wand_stop_ms = 0
local WAND_STOP_THROTTLE_MS = 100
local last_wand_attempt = 0
local WAND_THROTTLE_MS = 2000
 
-- Inventory slot for ranged weapon (wand)
local RANGED_WEAPON_SLOT_ID = 18

-- Facing helper (fixes cases where `izi.target()` is correct but we are not facing the target,
-- which can look like "rotation doesn't attack until I TAB".)
local last_face_fix_ms = 0
local FACE_FIX_THROTTLE_MS = 150

-- Tick tracker for mana optimization
local active_tick_tracker = nil

-- Forward-declare safe_is_alive (defined later ~line 576) so functions defined
-- before that line can reference it safely. Without this Lua sees a nil global.
local safe_is_alive

-- ============================================================================
-- POTION HELPER (Manual fallback for TBC potions)
-- ============================================================================
-- The SDK method izi.use_best_X_potion_safe() may not recognise TBC-specific
-- potions (Super Healing/Mana).  This helper iterates the explicit item-ID
-- lists from spells.lua via izi.item() and tries to use whichever potion the
-- player actually has in their bags.

---Try to use the best available potion from a list of item IDs.
---@param potion_ids table List of item IDs (highest rank first)
---@param reason string Debug label ("Mana Potion"/"Health Potion")
---@return boolean True if a potion was used
local function try_use_potion(potion_ids, reason)
    if not potion_ids then return false end
    for _, item_id in ipairs(potion_ids) do
        local ok, item = pcall(function() return izi.item(item_id) end)
        if ok and item then
            local has_it = false
            pcall(function() has_it = item:in_inventory() end)
            if has_it then
                local cd_ok = true
                pcall(function()
                    local cd = item:get_cooldown()
                    if cd and cd > 0 then cd_ok = false end
                end)
                if cd_ok then
                    local used = false
                    pcall(function() used = item:use_self_safe(reason) end)
                    if used then return true end
                end
            end
        end
    end
    return false
end
 
-- ============================================================================
-- DEBUG LOGGING (throttled, checkbox-gated)
-- ============================================================================

local _log_last_times = {}
local _active_menu_ref = nil  -- set each tick by execute()

---Throttled debug log. Only logs if debug checkbox is enabled and interval has elapsed.
---@param key string Unique key for throttling (e.g. "heal.tank_emergency")
---@param interval number Minimum seconds between logs with same key
---@param message string The log message
local function dbg(key, interval, message)
    if not _active_menu_ref then return end
    if not _active_menu_ref.rotation_log_enabled then return end
    if not _active_menu_ref.rotation_log_enabled:get_state() then return end

    local now = core.time()
    local last = _log_last_times[key] or 0
    if (now - last) < interval then return end
    _log_last_times[key] = now
    core.log("[Priest] " .. message)
end

---Immediate debug log (no throttle). Only logs if debug checkbox is enabled.
---@param message string
local function dbg_now(message)
    if not _active_menu_ref then return end
    if not _active_menu_ref.rotation_log_enabled then return end
    if not _active_menu_ref.rotation_log_enabled:get_state() then return end
    core.log("[Priest] " .. message)
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

---@param player game_object
---@return game_object|nil
local function get_current_target(player)
    local target = nil
    pcall(function() target = izi.target() end)
    if target and target.is_valid and target:is_valid() then
        return target
    end

    if player and player.get_target then
        local ok, player_target = pcall(function()
            return player:get_target()
        end)
        if ok and player_target and player_target.is_valid and player_target:is_valid() then
            return player_target
        end
    end

    return nil
end

---@param player game_object
---@param target game_object
---@return boolean did_face_action True if we issued (or are waiting on) a face/turn action.
local function ensure_facing_target(player, target)
    if not player or not target or not core or not core.input or not core.input.look_at then
        return false
    end
    if not player.is_looking_at or not target.get_position then
        return false
    end

    local ok_enemy, is_enemy = pcall(function()
        return target:is_valid_enemy()
    end)
    if not ok_enemy or is_enemy ~= true then
        return false
    end

    local ok_looking, looking = pcall(function()
        return player:is_looking_at(target)
    end)
    if ok_looking and looking == true then
        return false
    end

    local now_ms = core.game_time()
    if (now_ms - last_face_fix_ms) >= FACE_FIX_THROTTLE_MS then
        local pos = nil
        pcall(function() pos = target:get_position() end)
        if pos then
            last_face_fix_ms = now_ms
            pcall(function() core.input.look_at(pos) end)
        end
    end

    -- Not facing yet: consume the tick so we don't spam other casts that will also fail on facing.
    return true
end

---@param element any
---@return boolean
local function keybind_toggle_enabled(element)
    if not element or not plugin_helper or not plugin_helper.is_toggle_enabled then
        return false
    end
    local ok, enabled = pcall(function()
        return plugin_helper:is_toggle_enabled(element) == true
    end)
    return ok and enabled == true
end

---@param menu table
---@return boolean
local function healing_only_enabled(menu)
    if menu and menu.healing_only and menu.healing_only.get_state then
        local ok, val = pcall(menu.healing_only.get_state, menu.healing_only)
        if ok and val == true then
            return true
        end
    end

    return false
end

---Find the best target for Power Infusion
---@param player game_object
---@return game_object|nil
local function find_power_infusion_target(player)
    local group = GroupState.members
    if #group <= 1 then return player end

    local mages = {}
    local warlocks = {}
    local others = {}

    for _, ally in __object_safety.live_ipairs(group) do
        local in_range = false
        if safe_is_alive(ally) and safe_is_alive(player) then
            -- Use pcall to guard against SDK internal arithmetic crashes on range checks
            local ok_range, res = pcall(function() return ally:is_in_range(player, 30) end)
            in_range = ok_range and res
        end

        if in_range then
            local ok_class, class = pcall(function() return ally:get_class() end)
            if ok_class then
                if class == enums.class_id.MAGE then
                    table.insert(mages, ally)
                elseif class == enums.class_id.WARLOCK then
                    table.insert(warlocks, ally)
                elseif class == enums.class_id.PRIEST or class == enums.class_id.DRUID then
                    table.insert(others, ally)
                end
            end
        end
    end

    if #mages > 0 then return mages[1] end
    if #warlocks > 0 then return warlocks[1] end
    if #others > 0 then return others[1] end
    
    return player
end

---Check if we should wait for a mana tick before casting
---@param player game_object
---@param spell_cost number|nil Not used currently but kept for signature
---@return boolean
local function should_wait_for_mana_tick(player, spell_cost)
    if not active_tick_tracker then
        return false
    end

    local mana = player:get_power(enums.power_type.MANA) or 0
    local mana_max = player:get_max_power(enums.power_type.MANA) or 1
    
    -- Don't delay if we have plenty of mana (>50%)
    if (mana / mana_max) > 0.5 then
        return false
    end

    -- Don't delay if mana tick is far away (>500ms)
    local ms_to_tick = active_tick_tracker:mana_ms_to_next_tick()
    if ms_to_tick > 500 then
        return false
    end

    -- If we're outside the 5SR and about to get a tick, wait for it
    -- Note: 5SR check is done via is_5sr_active()
    if not is_5sr_active() and ms_to_tick < 300 then
        return true
    end

    return false
end


-- ============================================================================
-- WAND LOGIC (Ported from Mage/Warlock)
-- ============================================================================

---Check if player has a ranged weapon (wand) equipped
---@param player game_object
---@return boolean
local function has_ranged_weapon_equipped(player)
    if not player or not player.get_item_at_inventory_slot then
        return false
    end

    local ok, slot_info = pcall(function()
        return player:get_item_at_inventory_slot(RANGED_WEAPON_SLOT_ID)
    end)
    
    -- In some SDKs slot_info might be a table with id, others might have object
    if ok and slot_info then
        if slot_info.id and slot_info.id > 0 then return true end
        if slot_info.object then return true end
    end

    return false
end


---Sync wand auto-attack state
---@param player game_object
local function sync_wand_auto_active(player)
    if not auto_attack_helper or not auto_attack_helper.is_auto_attacking then
        wand_auto_active = false
        return
    end
    local ok, is_attacking = pcall(function()
        -- Note: Priest uses Ranged Attack (Wand) which is handled by the helper
        return auto_attack_helper:is_auto_attacking(player, auto_attack_helper.ATTACK_TYPE.WAND)
    end)
    wand_auto_active = ok and is_attacking == true
end

---Stop wand if active (exact warlock pattern)
---@param player game_object
---@param target game_object
local function stop_wand_if_active(player, target)
    if not auto_attack_helper or not auto_attack_helper.is_auto_attacking then return end
    local is_attacking = false
    pcall(function() is_attacking = auto_attack_helper:is_auto_attacking(player, auto_attack_helper.ATTACK_TYPE.WAND) end)
    if not is_attacking then return end
    auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.WAND)
end

---Safe spell cast
---@param spell any
---@param target game_object
---@param player game_object
---@return boolean
local function cast_spell(spell, target, player)
    if not spell or not target then return false end

    -- Check if learned and cooldown is up
    if not spell:is_learned() or not spell:cooldown_up() then
        return false
    end

    -- If we are not facing the target, try to face first. This prevents "needs TAB to start attacking"
    -- when the target is selected but outside the facing arc.
    if player and ensure_facing_target(player, target) then
        return true
    end

    -- Stop wand right before we actually cast a real spell
    stop_wand_if_active(player, target)

    local ok, result = pcall(function()
        return spell:cast_safe(target)
    end)
    if ok and result == true then
        local s_name, t_name, s_id = "?", "?", 0
        pcall(function() s_name = spell:get_name() or "?" end)
        pcall(function() t_name = target:get_name() or "?" end)
        pcall(function() s_id = spell:id() or 0 end)
        dbg_now(string.format("CAST OK: %s (id=%d) -> %s", s_name, s_id, t_name))
        return true
    end
    return false
end

---Check if wand auto-shoot is active (Warlock pattern: helper + channel fallback)
---@param player game_object
---@return boolean
local function is_wanding_active(player)
    if not auto_attack_helper then return false end
    local ok, attacking = pcall(function()
        return auto_attack_helper:is_auto_attacking(player, auto_attack_helper.ATTACK_TYPE.WAND)
    end)
    if ok and attacking == true then return true end
    -- Fallback: channel spell ID 5019 = Shoot (Wand)
    local ok2, pid = pcall(function() return player:get_active_channel_spell_id() end)
    return ok2 and pid == 5019
end

---Try to use wand as filler (Warlock pattern)
---@param player game_object
---@param target game_object
---@param menu table
---@param target_hp_pct number Current target HP percentage
---@param mana_pct number Current player mana percentage
---@return boolean
local function try_use_wand(player, target, menu, target_hp_pct, mana_pct)
    -- 1. Check enabled
    if menu.use_wand and not menu.use_wand:get_state() then return false end
    if not auto_attack_helper then return false end
    if player:is_moving() then return false end
    if player:is_channeling_or_casting() then return false end

    -- 2. Thresholds: wand when mana below threshold OR target HP below threshold
    local mana_threshold = (menu.solo_dps_mana and menu.solo_dps_mana:get()) or 15
    local hp_threshold   = (menu.wand_target_hp and menu.wand_target_hp:get()) or 10
    if mana_pct > mana_threshold and target_hp_pct > hp_threshold then
        return false
    end

    -- 3. Already wanding? Let it continue
    if is_wanding_active(player) then
        return true
    end

    -- 4. Start wand via auto_attack_helper (exact warlock pattern)
    local ok, result = pcall(function()
        return auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.WAND)
    end)
    if ok and result == true then
        dbg_now("Wand: Started auto-shoot on " .. (target:get_name() or "target"))
        return true
    end

    return false
end


---Select the optimal Greater Heal rank based on target health deficit and TBC penalty rules
---@param player game_object
---@param target game_object
---@param menu table
---@return any The spell object to cast
local function get_smart_greater_heal(player, target, menu)
    -- Read user-configured rank bounds (default: 1-7 = all ranks)
    local min_rank = 1
    local max_rank = 7
    pcall(function()
        if menu.gh_min_rank and menu.gh_min_rank.get then
            min_rank = menu.gh_min_rank:get() or 1
        end
        if menu.gh_max_rank and menu.gh_max_rank.get then
            max_rank = menu.gh_max_rank:get() or 7
        end
    end)
    -- Ensure min <= max
    if min_rank > max_rank then min_rank = max_rank end

    -- Rank objects initialized in spells.lua
    local rank_objects = {
        [1] = spells.gh_r1,
        [2] = spells.gh_r2,
        [3] = spells.gh_r3,
        [4] = spells.gh_r4,
        [5] = spells.gh_r5,
        [6] = spells.gh_r6,
        [7] = spells.gh_r7,
    }

    -- If smart downranking is disabled, use the user's max rank directly
    if not menu.enable_smart_downranking:get_state() then
        local max_obj = rank_objects[max_rank]
        if max_obj and max_obj:is_learned() then
            return max_obj
        end
        return spells.greater_heal
    end

    local missing_hp = target:get_max_health() - target:get_health()
    local player_level = player:get_level()
    local avoid_penalty = menu.downrank_penalty_prevention:get_state()

    -- Best fallback = user's min rank (lowest allowed)
    local best_fallback = rank_objects[min_rank] or spells.greater_heal
    
    -- Iterate from lowest rank to highest to find the first rank that heals "enough"
    -- This maximizes mana efficiency within the user's configured bounds.
    for i = #spells.GH_RANKS, 1, -1 do
        local rank_data = spells.GH_RANKS[i]
        
        -- Skip ranks outside user-configured bounds
        if rank_data.rank >= min_rank and rank_data.rank <= max_rank then
            local spell_object = rank_objects[rank_data.rank]
            
            if spell_object and spell_object:is_learned() then
                -- TBC Penalty check: Spells learned 10+ levels below player level
                local has_penalty = rank_data.level < (player_level - 10)
                
                if not (avoid_penalty and has_penalty) then
                    -- Does this rank heal enough? 
                    -- If it heals at least 90% of missing HP, it's efficient.
                    if rank_data.heal >= (missing_hp * 0.9) then
                        return spell_object
                    end
                    
                    -- Capture the highest learned non-penalized rank in bounds as fallback
                    best_fallback = spell_object
                end
            end
        end
    end

    return best_fallback
end

---Select the optimal standard Heal rank based on target health deficit and TBC penalty rules
---@param player game_object
---@param target game_object
---@param menu table
---@return any The spell object to cast
local function get_smart_heal(player, target, menu)
    -- If Heal is disabled, redirect to Greater Heal (Heal is obsolete at 70)
    if menu.use_heal and not menu.use_heal:get_state() then
        return get_smart_greater_heal(player, target, menu)
    end

    -- Read user-configured rank bounds (default: 1-4 = all ranks)
    local min_rank = 1
    local max_rank = 4
    pcall(function()
        if menu.h_min_rank and menu.h_min_rank.get then
            min_rank = menu.h_min_rank:get() or 1
        end
        if menu.h_max_rank and menu.h_max_rank.get then
            max_rank = menu.h_max_rank:get() or 4
        end
    end)
    -- Ensure min <= max
    if min_rank > max_rank then min_rank = max_rank end

    -- Rank objects initialized in spells.lua
    local rank_objects = {
        [1] = spells.h_r1,
        [2] = spells.h_r2,
        [3] = spells.h_r3,
        [4] = spells.h_r4,
    }

    -- If smart downranking is disabled, use the user's max rank directly
    if not menu.enable_smart_downranking:get_state() then
        local max_obj = rank_objects[max_rank]
        if max_obj and max_obj:is_learned() then
            return max_obj
        end
        return spells.heal
    end

    local missing_hp = target:get_max_health() - target:get_health()
    local player_level = player:get_level()
    local avoid_penalty = menu.downrank_penalty_prevention:get_state()

    -- Best fallback = user's min rank (lowest allowed)
    local best_fallback = rank_objects[min_rank] or spells.heal
    
    -- Iterate in reverse (lowest level rank first)
    for i = #spells.HEAL_RANKS, 1, -1 do
        local rank_data = spells.HEAL_RANKS[i]
        
        -- Skip ranks outside user-configured bounds
        if rank_data.rank >= min_rank and rank_data.rank <= max_rank then
            local spell_object = rank_objects[rank_data.rank]
            
            if spell_object and spell_object:is_learned() then
                -- TBC Penalty check: Spells learned 10+ levels below player level
                local has_penalty = rank_data.level < (player_level - 10)
                
                if not (avoid_penalty and has_penalty) then
                    if rank_data.heal >= (missing_hp * 0.9) then
                        return spell_object
                    end
                    best_fallback = spell_object
                end
            end
        end
    end

    return best_fallback
end

---Select the optimal Lesser Heal rank (for low mana fallback)
---@param player game_object
---@param target game_object
---@param menu table
---@return any The spell object to cast
local function get_smart_lesser_heal(player, target, menu)
    -- Lesser Heal is a very mana-efficient heal for low-level ranks
    -- Use when OOM or very low mana to keep healing without going completely dry
    if spells.lesser_heal and spells.lesser_heal:is_learned() then
        return spells.lesser_heal
    end
    -- Fallback: prefer Greater Heal R1 over Heal (Heal is obsolete at 70)
    if spells.gh_r1 and spells.gh_r1:is_learned() then
        return spells.gh_r1
    end
    -- Last resort: Heal R1 only if toggle allows it
    if menu and menu.use_heal and menu.use_heal:get_state() then
        if spells.h_r1 and spells.h_r1:is_learned() then
            return spells.h_r1
        end
    end
    return spells.greater_heal
end


---Check if player has enough mana
---@param player game_object
---@param min_mana_pct number
---@return boolean
local function has_enough_mana(player, min_mana_pct)
    return player:mana_pct() >= min_mana_pct
end

---Check if enemy has a dispellable magic buff
---@param unit game_object
---@return boolean
local function has_dispellable_magic_buff(unit)
    if not unit or not unit.get_buffs then return false end
    local ok, buffs = pcall(function() return unit:get_buffs() end)
    if not ok or type(buffs) ~= "table" then return false end
    for _, buff in ipairs(buffs) do
        if buff and buff.type == enums.buff_type.MAGIC then
            return true
        end
    end
    return false
end

---Get HP deficit of a unit
---@param unit game_object
---@return number
local function get_unit_deficit(unit)
    if not unit or not unit:is_alive() then return 0 end
    local max_hp = unit:get_max_health() or 1000
    local cur_hp = unit:get_health() or 1000
    return math.max(0, max_hp - cur_hp)
end

---Safely check if a unit is alive (guards invalid game objects)
---@param unit game_object
---@return boolean
safe_is_alive = function(unit)
    if not unit then
        return false
    end
    if unit.is_valid then
        local ok_valid, valid = pcall(function()
            return unit:is_valid()
        end)
        if not ok_valid or not valid then
            return false
        end
    end
    local ok_alive, alive = pcall(function()
        return unit:is_alive()
    end)
    return ok_alive and alive == true
end

---Cast a healing spell intelligently (supports downranking)
---@param spell_name string The name of the spell ("heal", "flash_heal", "renew", "circle_of_healing")
---@param target game_object The target to heal
---@param menu table The menu configuration
---@return boolean success
local function cast_smart(spell_name, target, menu)
    if not target or not target:is_alive() then return false end
    
    -- 1. Check if downranking is enabled
    if menu.use_downranking and menu.use_downranking:get_state() then
        local deficit = get_unit_deficit(target)
        local best_rank = nil
        
        -- Special handling for spells that need user-configured rank bounds
        if spell_name == "heal" then
            local best_obj = get_smart_heal(izi.me(), target, menu)
            if best_obj and cast_spell(best_obj, target, izi.me()) then
                return true
            end
        elseif spell_name == "flash_heal" then
            -- Read user-configured rank bounds for Flash Heal
            local min_rank = 1
            local max_rank = 9
            pcall(function()
                if menu.fh_min_rank and menu.fh_min_rank.get then
                    min_rank = menu.fh_min_rank:get() or 1
                end
                if menu.fh_max_rank and menu.fh_max_rank.get then
                    max_rank = menu.fh_max_rank:get() or 9
                end
            end)
            if min_rank > max_rank then min_rank = max_rank end

            -- In spells.lua, FLASH_HEAL_RANKS is 1-indexed Rank 1 to Rank 9
            local rank_table = spells.FLASH_HEAL_RANKS
            local target_heal = deficit * 1.1
            local best_fh = nil
            
            for rank_idx = min_rank, max_rank do
                local rank_data = rank_table[rank_idx]
                if rank_data then
                    local spell_obj = izi.spell(rank_data.id)
                    if spell_obj and spell_obj:is_learned() then
                        best_fh = spell_obj
                        if rank_data.heal_avg >= target_heal then
                            break
                        end
                    end
                end
            end
            
            if best_fh and cast_spell(best_fh, target, izi.me()) then
                return true
            end
        else
            -- Fallback for other spells (Renew, CoH) via generic spells:get_best_rank
            if type(spells.get_best_rank) == "function" then
                best_rank = spells:get_best_rank(spell_name, deficit)
            end
            
            if best_rank then
                local spell_obj = izi.spell(best_rank.id)
                if spell_obj and spell_obj:is_learned() and spell_obj:cooldown_up() then
                    if cast_spell(spell_obj, target, izi.me()) then
                        return true
                    end
                end
            end
        end
    end
    
    -- 2. Fallback: Use highest rank (via spells object)
    -- Redirect "heal" to "greater_heal" when Heal is disabled
    local effective_name = spell_name
    if spell_name == "heal" and menu.use_heal and not menu.use_heal:get_state() then
        effective_name = "greater_heal"
    end
    local main_spell = spells[effective_name]
    if main_spell and main_spell:is_learned() and main_spell:cooldown_up() then
        if cast_spell(main_spell, target, izi.me()) then
            core.log(string.format("Casting: %s (Max Rank) on %s", effective_name, target:get_name()))
            return true
        end
    end
    
    return false
end


---Check if unit is missing a specific buff
---@param unit game_object
---@param buff_ids table
---@return boolean
local function buff_missing(unit, buff_ids)
    if not unit or not unit:is_alive() then
        return false
    end
    
    for _, id in ipairs(buff_ids) do
        if unit:buff_up(id) then
            return false
        end
    end
    return true
end

---Check if unit has a specific buff
---@param unit game_object
---@param buff_ids table
---@return boolean
local function has_buff(unit, buff_ids)
    if not unit or not unit:is_alive() then
        return false
    end
    
    for _, id in ipairs(buff_ids) do
        if unit:buff_up(id) then
            return true
        end
    end
    return false
end

---Check if unit is a rage-based class (Warrior or Druid Bear)
---@param unit game_object
---@return boolean
local function is_rage_class(unit)
    if not unit or not unit:is_alive() then return false end
    local class = unit:get_class()
    return class == enums.class_id.WARRIOR or class == enums.class_id.DRUID
end

---Check if unit has Weakened Soul debuff
---@param unit game_object
---@return boolean
local function has_weakened_soul(unit)
    if not unit or not unit:is_alive() then
        return true
    end
    return unit:debuff_up(spells.WEAKENED_SOUL_ID)
end


---Check if unit needs dispel
---@param unit game_object
---@return boolean
local function needs_dispel(unit)
    if not safe_is_alive(unit) or not unit.get_debuffs then
        return false
    end
    
    local ok, debuffs = pcall(function()
        return unit:get_debuffs()
    end)
    if not ok or type(debuffs) ~= "table" then
        return false
    end
    
    for _, dtype in ipairs(spells.CLEANSE_TYPES) do
        local target_type = nil
        if dtype == "Magic" then
            target_type = enums.buff_type.MAGIC
        elseif dtype == "Disease" then
            target_type = enums.buff_type.DISEASE
        end
        
        if target_type then
            for _, debuff in ipairs(debuffs) do
                if debuff and debuff.type == target_type then
                    return true
                end
            end
        end
    end
    return false
end

---Check if unit needs magic dispel specifically
---@param unit game_object
---@return boolean
local function needs_magic_dispel(unit)
    if not safe_is_alive(unit) or not unit.get_debuffs then
        return false
    end
    
    local ok, debuffs = pcall(function()
        return unit:get_debuffs()
    end)
    if not ok or type(debuffs) ~= "table" then
        return false
    end
    
    for _, debuff in ipairs(debuffs) do
        if debuff and debuff.type == enums.buff_type.MAGIC then
            return true
        end
    end
    return false
end

---Count group members who need magic dispel
---@param player game_object
---@return integer
local function count_magic_dispels_needed(player)
    local count = 0
    local group = get_group_members(player)
    for _, ally in __object_safety.live_ipairs(group) do
        if safe_is_alive(ally) then
            if needs_magic_dispel(ally) then
                count = count + 1
            end
        end
    end
    return count
end

---Check if unit needs disease cure
---@param unit game_object
---@return boolean
local function needs_disease_cure(unit)
    if not safe_is_alive(unit) or not unit.get_debuffs then
        return false
    end
    
    local ok, debuffs = pcall(function()
        return unit:get_debuffs()
    end)
    if not ok or type(debuffs) ~= "table" then
        return false
    end
    
    for _, debuff in ipairs(debuffs) do
        if debuff and debuff.type == enums.buff_type.DISEASE then
            return true
        end
    end
    return false
end

local function get_group_members(player)
    local members = {}

    -- Safer Implementierung: benutze nur Party-APIs, kein get_raid_members

    -- 1) Versuche Party-Mitglieder im Umkreis (40y, inkl. self)
    local ok_range, party_range = pcall(function()
        return player:get_party_members_in_range(40, true)
    end)
    if ok_range and party_range and #party_range > 0 then
        return party_range
    end

    -- 2) Fallback: normale Party-Mitglieder
    local ok_party, party = pcall(function()
        return player:get_party_members()
    end)
    if ok_party and party and #party > 0 then
        return party
    end

    -- 3) Solo – nur den Spieler selbst zurückgeben
    table.insert(members, player)
    return members
end

---Refresh the global group state for this tick (One-pass optimization)
---@param player game_object
---@param menu table
local function refresh_group_state(player, menu)
    local now = core.game_time()
    
    -- Throttle member list refresh (expensive)
    if (now - GroupState.last_member_refresh) >= MEMBER_REFRESH_INTERVAL_MS or #GroupState.members == 0 then
        local old_count = #GroupState.members
        GroupState.members = get_group_members(player)
        GroupState.last_member_refresh = now
        if #GroupState.members ~= old_count then
            dbg_now(string.format("GROUP: member count changed %d -> %d", old_count, #GroupState.members))
        end
    end

    local prev_tank = GroupState.tank

    GroupState.lowest_ally = player
    GroupState.lowest_hp = player:get_health_percentage() or 100
    GroupState.tank = player
    GroupState.tank_hp = GroupState.lowest_hp
    GroupState.below_aoe_count = 0
    GroupState.below_coh_count = 0

    local aoe_hp = menu.aoe_hp_threshold:get()
    local coh_hp = (menu.coh_hp_threshold and menu.coh_hp_threshold:get()) or 85

    local found_tank = false
    local best_tank_priority = 100 -- Warrior=1, Pally=2, Druid=3

    for _, ally in __object_safety.live_ipairs(GroupState.members) do
        if safe_is_alive(ally) then
            local ok_hp, hp = pcall(function()
                return ally:get_health_percentage()
            end)
            hp = ok_hp and hp or 100

            -- Lowest HP detection
            if not GroupState.lowest_ally or hp < GroupState.lowest_hp then
                GroupState.lowest_hp = hp
                GroupState.lowest_ally = ally
            end

            -- Tank Detection
            local ok_class, class = pcall(function()
                return ally:get_class()
            end)
            if not ok_class then
                class = nil
            end
            local priority = 100
            if class == enums.class_id.WARRIOR then priority = 1
            elseif class == enums.class_id.PALADIN then priority = 2
            elseif class == enums.class_id.DRUID then priority = 3
            end

            if priority < best_tank_priority then
                best_tank_priority = priority
                GroupState.tank = ally
                GroupState.tank_hp = hp
            end

            -- AoE Counts
            if hp < aoe_hp then GroupState.below_aoe_count = GroupState.below_aoe_count + 1 end
            if hp < coh_hp then GroupState.below_coh_count = GroupState.below_coh_count + 1 end
        end
    end

    -- Log tank change (pcall guards stale game object references)
    pcall(function()
        if (not __object_safety.same(GroupState.tank,prev_tank)) then
            local new_tank_name = "?"
            pcall(function() new_tank_name = GroupState.tank:get_name() or "?" end)
            dbg_now(string.format("GROUP: tank changed -> %s (priority=%d hp=%d%%)", new_tank_name, best_tank_priority, math.floor(GroupState.tank_hp)))
        end
    end)

    -- Throttled Dispel Detection (Expensive API calls)
    local now = core.game_time()
    if (now - GroupState.last_dispel_refresh) >= DISPEL_CHECK_INTERVAL_MS then
        GroupState.last_dispel_refresh = now
        GroupState.dispel_magic = {}
        GroupState.dispel_disease = {}

        for _, ally in __object_safety.live_ipairs(GroupState.members) do
            if safe_is_alive(ally) and ally.get_debuffs then
                local ok, debuffs = pcall(function() return ally:get_debuffs() end)
                if ok and type(debuffs) == "table" then
                    local has_magic = false
                    local has_disease = false
                    for _, debuff in ipairs(debuffs) do
                        if debuff and debuff.type == enums.buff_type.MAGIC then has_magic = true end
                        if debuff and debuff.type == enums.buff_type.DISEASE then has_disease = true end
                        if has_magic and has_disease then break end
                    end
                    if has_magic then
                        local skip_fear = _active_menu_ref and _active_menu_ref.avoid_dispel_fear
                            and _active_menu_ref.avoid_dispel_fear:get_state()
                        if skip_fear then
                            local ok_feared, is_feared = pcall(function() return ally:is_feared() end)
                            if ok_feared and is_feared then
                                local f_name = ""
                                pcall(function() f_name = ally:get_name() or "?" end)
                                dbg("dispel.fear_skip", 2.0, string.format("Dispel SKIPPED: %s is feared", f_name))
                            else
                                table.insert(GroupState.dispel_magic, ally)
                            end
                        else
                            table.insert(GroupState.dispel_magic, ally)
                        end
                    end
                    if has_disease then table.insert(GroupState.dispel_disease, ally) end
                end
            end
        end
    end
end




---Check and maintain Shadowform
---@param player game_object
---@param menu table
---@return boolean
local function ensure_shadowform(player, menu)
    -- Check if enabled
    if not menu.maintain_shadowform:get_state() then
        return false
    end
    
    -- Check if learned
    if not spells.shadow_form:is_learned() then
        return false
    end
    
    -- Check if already active
    if has_buff(player, spells.SHADOWFORM_BUFF_IDS) then
        return false
    end
    
    -- Check if mounting or casting
    if player:is_mounted() or player:is_casting_spell() or player:is_channelling_spell() then
        return false
    end
    
    -- Cast it
    if spells.shadow_form:cast_safe(player) then
        return true
    end
    
    return false
end

-- (Wand helpers & cast_spell are defined earlier in the file, near line 210-278)
-- Do NOT redefine them here — Lua local functions shadow earlier definitions!

-- ============================================================================
-- OUT-OF-COMBAT LOGIC (BUFFS)
-- ============================================================================

---@param player game_object
---@param menu table
---@return boolean
local function handle_out_of_combat(player, menu)
    local now = core.game_time()

    -- Skip if casting
    if player:is_casting_spell() or player:is_channelling_spell() then
        dbg("ooc.cast", 2.0, "OOC: already casting/channeling, skip")
        return false
    end

    -- Maintain Shadowform (High priority out of combat)
    if ensure_shadowform(player, menu) then
        dbg("ooc.sf", 2.0, "OOC: applying Shadowform")
        return true
    end

    -- Check buffs periodically
    if now - last_buff_check < BUFF_CHECK_INTERVAL_MS then
        return false
    end
    last_buff_check = now

    -- Minimum mana requirement for buffing
    if not has_enough_mana(player, 20) then
        dbg("ooc.mana", 5.0, string.format("OOC buffs: not enough mana (%.0f%%)", player:mana_pct() or 0))
        return false
    end

    -- Check if buffs are enabled
    if not menu.use_buffs:get_state() then
        return false
    end

    dbg("ooc.buffs", 5.0, string.format("OOC buff scan: %d members", #GroupState.members))

    -- Inner Fire (self buff)
    if buff_missing(player, spells.INNER_FIRE_BUFF_IDS) then
        if spells.inner_fire:is_learned() then
            dbg("ooc.innerfire", 2.0, "OOC: applying Inner Fire")
            if cast_spell(spells.inner_fire, player, player) then
                return true
            end
        end
    end

    -- Get group members for buffing
    local group = GroupState.members

    -- Power Word: Fortitude (or Prayer of Fortitude for raids)
    for _, ally in __object_safety.live_ipairs(group) do
        if safe_is_alive(ally) then
            if buff_missing(ally, spells.FORTITUDE_BUFF_IDS) then
                local b_name = ""
                pcall(function() b_name = ally:get_name() or "?" end)
                -- Try Prayer of Fortitude first for groups
                if #group > 3 and spells.prayer_of_fortitude:is_learned() then
                    if has_enough_mana(player, 40) then
                        dbg("ooc.fort", 1.0, string.format("OOC: Prayer of Fortitude -> %s", b_name))
                        if cast_spell(spells.prayer_of_fortitude, ally, player) then
                            return true
                        end
                    end
                end
                -- Fall back to single target
                if spells.power_word_fortitude:is_learned() then
                    dbg("ooc.fort", 1.0, string.format("OOC: PW:Fortitude -> %s", b_name))
                    if cast_spell(spells.power_word_fortitude, ally, player) then
                        return true
                    end
                end
            end
        end
    end

    -- Divine Spirit (if talented)
    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() then
            -- Only buff mana users
            local mana = ally:get_power(enums.power_type.MANA)
            if mana and mana > 0 then
                if buff_missing(ally, spells.DIVINE_SPIRIT_BUFF_IDS) then
                    local b_name = ""
                    pcall(function() b_name = ally:get_name() or "?" end)
                    -- Try Prayer of Spirit first for groups
                    if #group > 3 and spells.prayer_of_spirit:is_learned() then
                        if has_enough_mana(player, 40) then
                            dbg("ooc.spirit", 1.0, string.format("OOC: Prayer of Spirit -> %s", b_name))
                            if cast_spell(spells.prayer_of_spirit, ally, player) then
                                return true
                            end
                        end
                    end
                    -- Fall back to single target
                    if spells.divine_spirit:is_learned() then
                        dbg("ooc.spirit", 1.0, string.format("OOC: Divine Spirit -> %s", b_name))
                        if cast_spell(spells.divine_spirit, ally, player) then
                            return true
                        end
                    end
                end
            end
        end
    end

    -- Shadow Protection (optional, mainly for dungeons)
    if menu.use_shadow_protection and menu.use_shadow_protection:get_state() then
        for _, ally in __object_safety.live_ipairs(group) do
            if safe_is_alive(ally) then
                if buff_missing(ally, spells.SHADOW_PROTECTION_BUFF_IDS) then
                    local b_name = ""
                    pcall(function() b_name = ally:get_name() or "?" end)
                    if spells.shadow_protection:is_learned() then
                        dbg("ooc.shadowprot", 1.0, string.format("OOC: Shadow Protection -> %s", b_name))
                        if cast_spell(spells.shadow_protection, ally, player) then
                            return true
                        end
                    end
                end
            end
        end
    end

    dbg("ooc.done", 5.0, "OOC: all buffs applied")
    return false
end

-- ============================================================================
-- MANA TICK / 5SR OPTIMIZATION (must be before handle_in_combat)
-- ============================================================================


---Check if we should delay casting to wait for mana tick
---@param player game_object
---@param spell_cost number Approximate mana cost of the spell
---@return boolean should_delay
local function should_wait_for_mana_tick(player, spell_cost)
    if not active_tick_tracker then
        return false
    end
    
    local mana = player:get_power(enums.power_type.MANA) or 0
    local mana_max = player:get_max_power(enums.power_type.MANA) or 1
    
    -- Don't delay if we have plenty of mana (>50%)
    if mana / mana_max > 0.5 then
        return false
    end
    
    -- Don't delay if mana tick is far away (>500ms)
    local ms_to_tick = active_tick_tracker:mana_ms_to_next_tick()
    if ms_to_tick > 500 then
        return false
    end
    
    -- If we're outside the 5SR and about to get a tick, wait for it
    local fsr_active = active_tick_tracker:fsr_active()
    if not fsr_active and ms_to_tick < 300 then
        return true
    end
    
    return false
end

---Check if casting now would waste mana regen (5SR optimization)
---@param player game_object
---@param is_emergency boolean
---@return boolean should_delay
local function should_delay_for_5sr(player, is_emergency)
    if not active_tick_tracker then
        return false
    end
    
    -- Never delay emergency heals
    if is_emergency then
        return false
    end
    
    local fsr_remaining = active_tick_tracker:fsr_remaining_ms()
    
    -- If 5SR is about to end (< 500ms remaining), wait for it
    if fsr_remaining > 0 and fsr_remaining < 500 then
        return true
    end
    
    return false
end

---Get time until next mana tick (for UI or logging)
---@return number ms_to_tick
local function get_ms_to_mana_tick()
    if not active_tick_tracker then
        return 2000
    end
    return active_tick_tracker:mana_ms_to_next_tick()
end

---Check if 5-Second Rule is currently active
---@return boolean
local function is_5sr_active()
    if not active_tick_tracker then
        return false
    end
    return active_tick_tracker:fsr_active()
end

---Get remaining 5SR time in ms
---@return number
local function get_5sr_remaining_ms()
    if not active_tick_tracker then
        return 0
    end
    return active_tick_tracker:fsr_remaining_ms()
end

-- ============================================================================
-- IN-COMBAT HEALING LOGIC
-- ============================================================================

---@param player game_object
---@param menu table
---@return boolean
local function handle_in_combat(player, menu)
    local now = core.game_time()
    
    -- Skip if casting or channeling (If we are already busy, keep doing it)
    if player:is_casting_spell() or player:is_channelling_spell() then
        -- Strict cancel-casting: if we are mid-cast on a direct heal, cancel immediately once the target is topped
        if player:is_casting_spell() and menu.enable_cancel_casting and menu.enable_cancel_casting:get_state() then
            local active_spell_id = 0
            pcall(function() active_spell_id = player:get_active_spell_id() or 0 end)

            if DIRECT_HEAL_SPELL_IDS[active_spell_id] then
                local cast_target = nil
                pcall(function() cast_target = player:get_active_spell_target() end)

                if cast_target and safe_is_alive(cast_target) then
                    local target_hp = cast_target:get_health_percentage() or 100
                    local cast_pct = 0
                    pcall(function() cast_pct = player:get_cast_pct() or 0 end)

                    local cancel_hp = (menu.cancel_cast_target_hp and menu.cancel_cast_target_hp.get and menu.cancel_cast_target_hp:get()) or 95
                    local stop_hp = (menu.stop_healing_hp and menu.stop_healing_hp.get and menu.stop_healing_hp:get()) or 100
                    local effective_cancel_hp = math.min(cancel_hp, stop_hp)

                    local ct_name = "?"
                    pcall(function() ct_name = cast_target:get_name() or "?" end)

                    if target_hp >= effective_cancel_hp then
                        local cast_start = 0
                        pcall(function() cast_start = player:get_active_spell_cast_start_time() or 0 end)

                        -- Throttle: don't cancel the same cast more than once
                        if (now - last_cancel_attempt_ms) < 100 then
                            dbg("cast.cancel.throttle", 1.0, string.format(
                                "CANCEL-CAST THROTTLED (time): spell=%d target=%s hp=%d%% cast=%d%% (threshold=%d%%)",
                                active_spell_id, ct_name, math.floor(target_hp), math.floor(cast_pct), effective_cancel_hp
                            ))
                        elseif cast_start == last_cancel_cast_start_time and active_spell_id == last_cancel_spell_id then
                            dbg("cast.cancel.throttle", 1.0, string.format(
                                "CANCEL-CAST THROTTLED: spell=%d target=%s hp=%d%% cast=%d%% (threshold=%d%%)",
                                active_spell_id, ct_name, math.floor(target_hp), math.floor(cast_pct), effective_cancel_hp
                            ))
                        else
                            last_cancel_cast_start_time = cast_start
                            last_cancel_spell_id = active_spell_id
                            last_cancel_attempt_ms = now

                            dbg_now(string.format(
                                "CANCEL-CAST: spell=%d target=%s hp=%d%% cast=%d%% (threshold=%d%%)",
                                active_spell_id, ct_name, math.floor(target_hp), math.floor(cast_pct), effective_cancel_hp
                            ))
                            pcall(function() core.input.cancel_spells() end)
                            return false -- Let the rotation re-evaluate targets next tick
                        end
                    else
                        dbg("cast.eval", 1.0, string.format(
                            "CASTING: spell=%d target=%s hp=%d%% cast=%d%% (cancel_at=%d%%)",
                            active_spell_id, ct_name, math.floor(target_hp), math.floor(cast_pct), effective_cancel_hp
                        ))
                    end
                end
            end
        end
        return true
    end
    
    local hp_pct = player:get_health_percentage()
    local mana_pct = player:mana_pct()
    local is_moving = player:is_moving()
    
    -- Get menu thresholds
    local tank_emergency_hp = menu.tank_emergency_hp:get()
    local player_emergency_hp = menu.player_emergency_hp:get()
    local flash_heal_hp = menu.flash_heal_hp:get()
    local heal_hp = menu.heal_hp:get()
    local renew_hp = menu.renew_refresh_hp:get()
    local shield_hp = menu.shield_hp:get()
    local aoe_threshold = menu.group_aoe_threshold:get()
    local aoe_hp = menu.aoe_hp_threshold:get()
    local mana_low = menu.mana_low_threshold:get()

    -- Group state summary (throttled every 2s)
    local _tank = GroupState.tank
    local _tank_name = (_tank and pcall(function() return _tank:get_name() end)) and _tank:get_name() or "?"
    local _low = GroupState.lowest_ally
    local _low_name = (_low and pcall(function() return _low:get_name() end)) and _low:get_name() or "?"
    dbg("grp.state", 2.0, string.format("HP=%.0f%% Mana=%.0f%% | Tank=%s(%d%%) Lowest=%s(%d%%) AoE_low=%d CoH_low=%d | moving=%s",
        hp_pct, mana_pct, _tank_name, GroupState.tank_hp, _low_name, GroupState.lowest_hp,
        GroupState.below_aoe_count, GroupState.below_coh_count, tostring(is_moving)))

    -- ========================================================================
    -- PRIORITY 1: Self Emergency (Desperate Prayer)
    -- ========================================================================

    if menu.use_desperate_prayer:get_state() and player:is_in_combat() then
        if hp_pct <= menu.desperate_prayer_hp:get() then
            if spells.desperate_prayer:is_learned() then
                dbg_now(string.format("P1 Desperate Prayer: self HP=%.0f%%", hp_pct))
                if cast_spell(spells.desperate_prayer, player, player) then
                    return true
                end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 2: Health Potion (Self Emergency)
    -- ========================================================================
    
    -- ========================================================================
    -- PRIORITY 2: Health Potion (Self Emergency)
    -- ========================================================================
    
    if menu.use_hp_potions:get_state() and player:is_in_combat() then
        local hp_pot_threshold = menu.hp_potion_at:get()
        if hp_pct <= hp_pot_threshold then
            dbg_now(string.format("P2 Health Potion: self HP=%.0f%% (threshold=%d%%)", hp_pct, hp_pot_threshold))
            -- Try SDK method first, then manual fallback with TBC item IDs
            if izi.use_best_health_potion_safe() then
                return true
            end
            if try_use_potion(spells.HEALTH_POTION_IDS, "Health Potion") then
                dbg_now("P2 Health Potion: manual fallback used")
                return true
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 3: Fade (Threat Emergency)
    -- ========================================================================
    
    -- ========================================================================
    -- PRIORITY 3: Fade (Threat Emergency)
    -- ========================================================================
    
    if menu.use_fade:get_state() and player:is_in_combat() then
        -- Check if we have aggro on any enemy
        local target = izi.target()
        if target and target:is_valid_enemy() then
            local threat_info = player:get_threat_situation(target)
            if threat_info then
                local is_tanking = threat_info.is_tanking or false
                local threat_pct = threat_info.threat_percent or 0
                
                if is_tanking or threat_pct > 90 then
                    if spells.fade:is_learned() then
                        dbg_now(string.format("P3 Fade: tanking=%s threat=%.0f%%", tostring(is_tanking), threat_pct))
                        if cast_spell(spells.fade, player, player) then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    -- ========================================================================
    -- GROUP SUPPORT HEALING (Gated by enable_healing toggle)
    -- ========================================================================

    local support_healing_enabled = menu.enable_healing:get_state()

    -- Global stop-healing guard: skip group healing if nobody needs it
    local stop_hp = menu.stop_healing_hp:get()
    if GroupState.lowest_hp >= stop_hp and GroupState.tank_hp >= stop_hp then
        dbg("heal.stop", 3.0, string.format("STOP: all above %d%% (lowest=%d%% tank=%d%%)", stop_hp, math.floor(GroupState.lowest_hp), math.floor(GroupState.tank_hp)))
        return false
    end
    
    -- ========================================================================
    -- PRIORITY 4: Prayer of Mending (maintenance)
    -- ========================================================================

    if support_healing_enabled and menu.use_prayer_of_mending and menu.use_prayer_of_mending:get_state() then
        if spells.prayer_of_mending:is_learned() then
            local pom_target = GroupState.tank
            if pom_target and pom_target:is_alive() then
                local pom_hp = pom_target:get_health_percentage() or 100
                if pom_hp <= heal_hp and not pom_target:buff_up(spells.POM_BUFF_IDS) then
                    dbg("heal.pom", 1.0, string.format("P4 POM: casting on tank %s (hp=%d%% threshold=%d%%)", _tank_name, math.floor(pom_hp), heal_hp))
                    if cast_spell(spells.prayer_of_mending, pom_target, player) then
                        return true
                    end
                end
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 5: Shadowfiend (mana management)
    -- ========================================================================

    if menu.use_shadowfiend and menu.use_shadowfiend:get_state() then
        if spells.shadowfiend:is_learned() and player:is_in_combat() then
            local threshold = (menu.shadowfiend_mana_threshold and menu.shadowfiend_mana_threshold:get()) or spells.DEFAULTS.SHADOWFIEND_MANA_THRESHOLD
            if mana_pct <= threshold then
                local sf_target = izi.target()
                if not (sf_target and sf_target:is_valid_enemy() and sf_target:is_alive()) then
                    local ts_targets = izi.get_ts_targets()
                    if ts_targets and ts_targets[1] and ts_targets[1]:is_valid_enemy() and ts_targets[1]:is_alive() then
                        sf_target = ts_targets[1]
                    end
                end

                if sf_target and sf_target:is_valid_enemy() and sf_target:is_alive() then
                    dbg("heal.sf", 2.0, string.format("P5 Shadowfiend: mana=%d%% (threshold=%d%%)", math.floor(mana_pct), threshold))
                    if cast_spell(spells.shadowfiend, sf_target, player) then
                        return true
                    end
                else
                    dbg("heal.sf.notgt", 5.0, string.format("P5 Shadowfiend: no valid enemy target (mana=%d%%)", math.floor(mana_pct)))
                end
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 6: Tank Emergency Healing
    -- ========================================================================
    
    local tank = GroupState.tank
    local tank_hp = GroupState.tank_hp
    
    if tank and tank:is_alive() and tank_hp <= tank_emergency_hp then
        dbg_now(string.format("P6 TANK EMERGENCY: %s at %d%% (threshold=%d%%)", _tank_name, math.floor(tank_hp), tank_emergency_hp))
        -- Pain Suppression (Tank external CD)
        if support_healing_enabled and menu.use_pain_suppression and menu.use_pain_suppression:get_state() then
            if spells.pain_suppression:is_learned() then
                if not tank:buff_up(spells.PAIN_SUPPRESSION_BUFF_IDS) then
                    dbg_now(string.format("P6 Pain Suppression: tank %s at %d%%", _tank_name, math.floor(tank_hp)))
                    if cast_spell(spells.pain_suppression, tank, player) then
                        return true
                    end
                end
            end
        end

        -- Binding Heal: when both player and tank are low (efficient emergency)
        if menu.use_binding_heal and menu.use_binding_heal:get_state() then
            if spells.binding_heal:is_learned() and not is_moving then
                if hp_pct <= player_emergency_hp and tank_hp <= flash_heal_hp then
                    dbg_now(string.format("P6 Binding Heal: self=%d%% tank %s=%d%%", math.floor(hp_pct), _tank_name, math.floor(tank_hp)))
                    if cast_spell(spells.binding_heal, tank, player) then
                        return true
                    end
                end
            end
        end

        -- Inner Focus for mana efficiency on big heals
        if menu.use_inner_focus:get_state() and not is_moving then
            if spells.inner_focus:is_learned() then
                if (now - last_inner_focus_use) > INNER_FOCUS_THROTTLE_MS then
                    dbg_now("P6 Inner Focus: pre-heal mana saver")
                    if cast_spell(spells.inner_focus, player, player) then
                        last_inner_focus_use = now
                        -- Don't return, continue to cast heal
                    end
                end
            end
        end
        
        -- Power Word: Shield (Smart check: Avoid shielding Rage classes unless VERY low HP)
        local is_rage = is_rage_class(tank)
        local use_shield_enabled = menu.use_shield:get_state()
        local should_shield = use_shield_enabled and (not is_rage or (not menu.avoid_shield_on_rage_tanks:get_state()) or (tank_hp <= 15))
        
        if should_shield and not has_weakened_soul(tank) then
            if spells.power_word_shield:is_learned() then
                dbg_now(string.format("P6 Tank Shield: %s at %d%%", _tank_name, math.floor(tank_hp)))
                if cast_spell(spells.power_word_shield, tank, player) then
                    return true
                end
            end
        end

        -- Flash Heal (fast, expensive)
        if menu.use_flash_heal:get_state() and not is_moving and has_enough_mana(player, 15) then
            dbg_now(string.format("P6 Tank Flash Heal: %s at %d%%", _tank_name, math.floor(tank_hp)))
            if cast_smart("flash_heal", tank, menu) then
                return true
            end
        end

        -- Greater Heal (slow but efficient at low HP)
        if menu.use_greater_heal:get_state() and not is_moving and has_enough_mana(player, 20) then
            dbg_now(string.format("P6 Tank Greater Heal: %s at %d%%", _tank_name, math.floor(tank_hp)))
            local gh_spell = get_smart_greater_heal(player, tank, menu)
            if gh_spell and gh_spell:is_learned() then
                if cast_spell(gh_spell, tank, player) then
                    return true
                end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 5: Emergency Healing (Any Ally)
    -- ========================================================================
    
    local lowest_ally, lowest_hp = GroupState.lowest_ally, GroupState.lowest_hp
    
    if support_healing_enabled and lowest_ally and lowest_hp <= player_emergency_hp then
        dbg_now(string.format("P5 ALLY EMERGENCY: %s at %d%% (threshold=%d%%)", _low_name, math.floor(lowest_hp), player_emergency_hp))
        -- Power Word: Shield (Smart check)
        local is_rage = is_rage_class(lowest_ally)
        local use_shield_enabled = menu.use_shield:get_state()
        local should_shield = use_shield_enabled and (not is_rage or (not menu.avoid_shield_on_rage_tanks:get_state()) or (lowest_hp <= 15))

        if should_shield and not has_weakened_soul(lowest_ally) then
            if spells.power_word_shield:is_learned() then
                dbg_now(string.format("P5 Ally Shield: %s at %d%%", _low_name, math.floor(lowest_hp)))
                if cast_spell(spells.power_word_shield, lowest_ally, player) then
                    return true
                end
            end
        end

        -- Flash Heal
        if menu.use_flash_heal:get_state() and not is_moving and has_enough_mana(player, 15) then
            dbg_now(string.format("P5 Ally Flash Heal: %s at %d%%", _low_name, math.floor(lowest_hp)))
            if cast_smart("flash_heal", lowest_ally, menu) then
                return true
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 6: AoE Healing (Circle of Healing / Prayer of Healing)
    -- ========================================================================
    
    if support_healing_enabled and menu.enable_aoe:get_state() then
        -- 6.1 Circle of Healing (TBC Talent - Instant, very efficient on group)
        if menu.use_circle_of_healing:get_state() and spells.circle_of_healing:is_learned() then
            local coh_count = GroupState.below_coh_count
            
            if coh_count >= menu.coh_min_targets:get() then
                dbg("heal.coh", 1.0, string.format("P6 CoH: %d targets below %d%%", coh_count, (menu.coh_hp_threshold and menu.coh_hp_threshold:get()) or 85))
                if cast_smart("circle_of_healing", lowest_ally or player, menu) then
                    return true
                end
            end
        end

        -- 6.2 Prayer of Healing (Classic AoE - Slow but powerful)
        if not is_moving then
            local low_count = GroupState.below_aoe_count
            
            if low_count >= aoe_threshold then
                dbg("heal.poh", 1.0, string.format("P6 PoH: %d targets below %d%%", low_count, aoe_hp))
                if spells.prayer_of_healing:is_learned() then
                    if has_enough_mana(player, 35) then
                        if cast_spell(spells.prayer_of_healing, player, player) then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 7: Flash Heal (Medium Emergency)
    -- ========================================================================
    
    if support_healing_enabled and menu.use_flash_heal:get_state() and lowest_ally and lowest_hp <= flash_heal_hp then
        -- Fresh HP check to avoid healing already-topped targets
        local fresh_flash_hp = lowest_ally:get_health_percentage() or 100
        if fresh_flash_hp <= flash_heal_hp then
            if not is_moving and has_enough_mana(player, 15) then
                dbg("heal.flash", 0.5, string.format("P7 Flash Heal: %s cached=%d%% fresh=%d%% (threshold=%d%%)", _low_name, math.floor(lowest_hp), math.floor(fresh_flash_hp), flash_heal_hp))
                if cast_smart("flash_heal", lowest_ally, menu) then
                    return true
                end
            end
        else
            dbg("heal.flash.skip", 1.0, string.format("P7 Flash Heal SKIPPED: %s cached=%d%% fresh=%d%% (threshold=%d%%)", _low_name, math.floor(lowest_hp), math.floor(fresh_flash_hp), flash_heal_hp))
        end
    end
    
    -- ========================================================================
    -- PRIORITY 7.5: Dispel Mind Control (Charmed Allies)
    -- ========================================================================
    
    if support_healing_enabled and menu.use_dispel:get_state() and menu.use_dispel_magic:get_state() then
        -- MC'd allies become hostile and drop from get_party_members_in_range().
        -- Scan the raw party list for hostile members (=Mind Controlled).
        local mc_ok, mc_group = pcall(function() return player:get_party_members() end)
        if mc_ok and mc_group then
            for _, ally in __object_safety.live_ipairs(mc_group) do
                if ally and safe_is_alive(ally) then
                    local is_hostile = false
                    pcall(function() is_hostile = ally:is_valid_enemy() end)
                    if is_hostile then
                        local mc_name = ""
                        pcall(function() mc_name = ally:get_name() or "?" end)
                        dbg_now(string.format("P7.5 MC DISPEL: %s is charmed!", mc_name))
                        if spells.dispel_magic:is_learned() then
                            if cast_spell(spells.dispel_magic, ally, player) then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 8: Dispel / Cure Disease
    -- ========================================================================
    
    if support_healing_enabled and menu.use_dispel:get_state() then
        if (now - last_dispel_check) >= DISPEL_CHECK_INTERVAL_MS then
            last_dispel_check = now

            local magic_count = #GroupState.dispel_magic
            local disease_count = #GroupState.dispel_disease
            if magic_count > 0 or disease_count > 0 then
                dbg("heal.dispel", 1.0, string.format("P8 Dispel scan: magic=%d disease=%d", magic_count, disease_count))
            end

            -- Magic Dispel
            if menu.use_dispel_magic:get_state() then
                for _, ally in __object_safety.live_ipairs(GroupState.dispel_magic) do
                    if ally and ally:is_alive() then
                        local d_name = ""
                        pcall(function() d_name = ally:get_name() or "?" end)

                        -- Mass Dispel (TBC) - only when multiple allies need magic dispel
                        if menu.use_mass_dispel and menu.use_mass_dispel:get_state() then
                            if spells.mass_dispel:is_learned() and not is_moving then
                                local min_targets = (menu.mass_dispel_min_targets and menu.mass_dispel_min_targets:get()) or 2
                                if magic_count >= min_targets then
                                    dbg_now(string.format("P8 Mass Dispel: %d targets (min=%d)", magic_count, min_targets))
                                    if cast_spell(spells.mass_dispel, ally, player) then
                                        return true
                                    end
                                end
                            end
                        end

                        dbg_now(string.format("P8 Dispel Magic: %s", d_name))
                        if spells.dispel_magic:is_learned() then
                            if cast_spell(spells.dispel_magic, ally, player) then
                                return true
                            end
                        end
                    end
                end
            end

            -- Disease Cure
            for _, ally in __object_safety.live_ipairs(GroupState.dispel_disease) do
                if ally and ally:is_alive() then
                    local d_name = ""
                    pcall(function() d_name = ally:get_name() or "?" end)
                    -- Prefer Abolish Disease (HoT effect)
                    if spells.abolish_disease:is_learned() then
                        dbg_now(string.format("P8 Abolish Disease: %s", d_name))
                        if cast_spell(spells.abolish_disease, ally, player) then
                            return true
                        end
                    elseif spells.cure_disease:is_learned() then
                        dbg_now(string.format("P8 Cure Disease: %s", d_name))
                        if cast_spell(spells.cure_disease, ally, player) then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 9: Greater Heal (Primary Heal with Smart Downranking)
    -- TBC Meta: Greater Heal (downranked) is the bread-and-butter heal at 70.
    -- Regular "Heal" is obsolete — GH Rank 1 (~950 heal) covers minor deficits.
    -- get_smart_greater_heal() picks the optimal rank based on HP deficit.
    -- ========================================================================
    
    if support_healing_enabled and menu.use_greater_heal:get_state() and lowest_ally and lowest_hp <= heal_hp then
        -- Fresh HP check to avoid starting a long cast on an already-healed target
        local fresh_heal_hp = lowest_ally:get_health_percentage() or 100
        if fresh_heal_hp <= heal_hp then
            if not is_moving then
                -- 5SR Optimization: Wait if 5SR is about to end for non-emergency heals
                local is_urgent = fresh_heal_hp <= 50
                if not is_urgent and should_delay_for_5sr(player, false) then
                    dbg("heal.5sr", 1.0, "P9 GH DELAYED: waiting for 5SR to end")
                    return false
                end

                -- Mana tick optimization: wait for tick if close and low mana
                if not is_urgent and should_wait_for_mana_tick(player, 400) then
                    dbg("heal.mana_tick", 1.0, "P9 GH DELAYED: waiting for mana tick")
                    return false
                end

                -- Always use Greater Heal (smart downranking picks optimal rank)
                -- GH R1 (~950) for small deficits, up to max rank for critical
                if has_enough_mana(player, 15) then
                    local deficit = 0
                    pcall(function()
                        deficit = lowest_ally:get_max_health() - lowest_ally:get_health()
                    end)
                    dbg("heal.gh", 0.5, string.format("P9 Greater Heal: %s fresh=%d%% deficit=%d", _low_name, math.floor(fresh_heal_hp), deficit))
                    local gh_spell = get_smart_greater_heal(player, lowest_ally, menu)
                    if gh_spell and gh_spell:is_learned() then
                        if cast_spell(gh_spell, lowest_ally, player) then
                            return true
                        end
                    end
                end
            end
        else
            dbg("heal.gh.skip", 1.0, string.format("P9 GH SKIPPED: %s cached=%d%% fresh=%d%% (threshold=%d%%)", _low_name, math.floor(lowest_hp), math.floor(fresh_heal_hp), heal_hp))
        end
    end
    
    -- ========================================================================
    -- PRIORITY 10: Lesser Heal Fallback (Low Mana / OOM Recovery)
    -- ========================================================================
    
    if support_healing_enabled and menu.use_lesser_heal_fallback and menu.use_lesser_heal_fallback:get_state() then
        if (mana_pct < mana_low or mana_pct < 10) then
            if lowest_ally and lowest_hp <= heal_hp then
                if not is_moving then
                    local lh_spell = get_smart_lesser_heal(player, lowest_ally, menu)
                    if lh_spell and lh_spell:is_learned() then
                        dbg("heal.lh", 0.5, string.format("P10 Lesser Heal: %s at %d%% (mana=%d%%)", _low_name, math.floor(lowest_hp), math.floor(mana_pct)))
                        if cast_spell(lh_spell, lowest_ally, player) then
                            core.log(string.format("Lesser Heal Fallback: Casting on %s (Mana: %d%%)", lowest_ally:get_name(), math.floor(mana_pct)))
                            return true
                        end
                    end
                else
                    dbg("heal.lh.move", 1.0, string.format("P10 Lesser Heal BLOCKED: moving (target=%s at %d%%)", _low_name, math.floor(lowest_hp)))
                end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 11: Renew (Preventive HoT with 5SR Optimization)
    -- ========================================================================
    
    if support_healing_enabled and menu.use_renew:get_state() then
        -- Renew is low priority - optimize for mana
        -- Wait for 5SR to end if close
        if should_delay_for_5sr(player, false) then
            dbg("heal.renew.5sr", 2.0, "P11 Renew DELAYED: waiting for 5SR")
            return false
        end

        -- Wait for mana tick if close
        if should_wait_for_mana_tick(player, 200) then
            dbg("heal.renew.tick", 2.0, "P11 Renew DELAYED: waiting for mana tick")
            return false
        end

        local group = GroupState.members

        -- Find the lowest HP ally that needs Renew (not just the first one)
        local best_renew_target = nil
        local best_renew_hp = 100

        for _, ally in __object_safety.live_ipairs(group) do
            if ally and ally:is_alive() then
                local ally_hp = ally:get_health_percentage() or 100

                if ally_hp <= renew_hp and ally_hp < best_renew_hp then
                    if buff_missing(ally, spells.RENEW_BUFF_IDS) then
                        best_renew_target = ally
                        best_renew_hp = ally_hp
                    end
                end
            end
        end

        if best_renew_target and has_enough_mana(player, 10) then
            local a_name = ""
            pcall(function() a_name = best_renew_target:get_name() or "?" end)
            dbg("heal.renew", 0.5, string.format("P11 Renew: %s at %d%% (threshold=%d%%)", a_name, math.floor(best_renew_hp), renew_hp))
            if cast_smart("renew", best_renew_target, menu) then
                return true
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 11: Power Word: Shield (Preventive)
    -- ========================================================================
    
    if support_healing_enabled and menu.use_shield:get_state() then
        -- Shield tank first
        if tank and tank:is_alive() then
            local tank_hp_now = tank:get_health_percentage() or 100
            if tank_hp_now <= shield_hp then
                -- Preventive Shield: SKIP Rage classes entirely if smart shielding is ON
                local is_rage = is_rage_class(tank)
                local skip_rage = is_rage and menu.avoid_shield_on_rage_tanks:get_state()

                if skip_rage then
                    dbg("heal.pws.prev", 2.0, string.format("P11 Shield SKIPPED: tank %s is rage class (hp=%d%%)", _tank_name, math.floor(tank_hp_now)))
                elseif has_weakened_soul(tank) then
                    dbg("heal.pws.prev", 2.0, string.format("P11 Shield BLOCKED: tank %s has Weakened Soul (hp=%d%%)", _tank_name, math.floor(tank_hp_now)))
                else
                    if spells.power_word_shield:is_learned() then
                        if has_enough_mana(player, 15) then
                            dbg("heal.pws.prev", 0.5, string.format("P11 Shield preventive: tank %s at %d%% (threshold=%d%%)", _tank_name, math.floor(tank_hp_now), shield_hp))
                            if cast_spell(spells.power_word_shield, tank, player) then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 12: Cooldowns (Power Infusion)
    -- ========================================================================
    
    if support_healing_enabled and menu.use_power_infusion:get_state() then
        if spells.power_infusion:is_learned() then
            -- Use on DPS caster in group, or self if solo
            local pi_target = find_power_infusion_target(player)
            if pi_target then
                local pi_name = ""
                pcall(function() pi_name = pi_target:get_name() or "?" end)
                dbg("heal.pi", 2.0, string.format("P12 Power Infusion: target=%s", pi_name))
                if cast_spell(spells.power_infusion, pi_target, player) then
                    return true
                end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 13: Mana Potion
    -- ========================================================================
    
    -- ========================================================================
    -- PRIORITY 13: Mana Potion
    -- ========================================================================
    
    if menu.use_mana_potions:get_state() and player:is_in_combat() then
        local pot_threshold = menu.mana_potion_at:get()
        if mana_pct <= pot_threshold then
            dbg("heal.pot", 2.0, string.format("P13 Mana Potion: mana=%d%% (threshold=%d%%)", math.floor(mana_pct), pot_threshold))
            -- Try SDK method first, then manual fallback with TBC item IDs
            if izi.use_best_mana_potion_safe() then
                return true
            end
            if try_use_potion(spells.MANA_POTION_IDS, "Mana Potion") then
                dbg_now("P13 Mana Potion: manual fallback used")
                return true
            end
        end
    end

    dbg("heal.idle", 3.0, string.format("IDLE: no action taken (hp=%d%% mana=%d%% lowest=%s at %d%%)", math.floor(hp_pct), math.floor(mana_pct), _low_name, math.floor(lowest_hp)))
    return false
end

-- ============================================================================
-- SHADOW DPS ROTATION (Solo/Leveling)
-- ============================================================================

---@param player game_object
---@param menu table
---@param target_override game_object|nil Optional target to use (bypasses TS when provided)
---@return boolean
local function handle_shadow_dps(player, menu, target_override)
    if not menu.enable_shadow_dps:get_state() then
        return false
    end

    -- Skip if already casting (Return true to keep the bot engine focused)
    if player:is_casting_spell() then
        dbg("dps.cast", 2.0, "DPS: currently casting, waiting")
        return true
    end

    local targets = {}
    if target_override and target_override:is_valid() and target_override:is_alive() then
        targets = { target_override }
    else
        targets = izi.get_ts_targets()
    end

    -- TS can be empty depending on profile/role; fall back to current target.
    if (not targets or #targets == 0) then
        local t = get_current_target(player)
        if t and t:is_valid_enemy() and t:is_alive() then
            targets = { t }
        end
    end

    if not targets or #targets == 0 then
        dbg("dps.notgt", 5.0, "DPS: no valid targets found")
        return false
    end

    local now = core.game_time()

    for i = 1, #targets do
        local target = targets[i]
        
        -- Basic Validity Checks
        if not target or not target:is_valid() then goto continue end
        -- Safely check damage immunity (target.DMG may not exist on all game objects)
        local ok_immune, is_immune = pcall(function()
            return target:is_damage_immune(target.DMG.MAGICAL)
        end)
        if ok_immune and is_immune then goto continue end

        local hp_pct = player:get_health_percentage() or 100
        local mana_pct = player:mana_pct() or 0
        local is_moving = player:is_moving()
        local target_hp_pct = target:get_health_percentage() or 100
        local has_shadowform = has_buff(player, spells.SHADOWFORM_BUFF_IDS)

        local t_name = ""
        pcall(function() t_name = target:get_name() or "?" end)
        dbg("dps.tick", 2.0, string.format("DPS: target=%s hp=%d%% | self hp=%d%% mana=%d%% shadow=%s moving=%s",
            t_name, math.floor(target_hp_pct), math.floor(hp_pct), math.floor(mana_pct), tostring(has_shadowform), tostring(is_moving)))

        -- ========================================================================
        -- 1. UTILITY / MAINTENANCE (Self Buffs)
        -- ========================================================================

        -- Power Word: Shield (Solo/Leveling protection)
        if i == 1 and menu.use_shield:get_state() then
            if hp_pct < 95 and not has_weakened_soul(player) and not has_buff(player, spells.PWS_BUFF_IDS) then
                dbg_now(string.format("DPS: self-shield hp=%d%%", math.floor(hp_pct)))
                if cast_spell(spells.power_word_shield, player, player) then return true end
            end
        end

        -- Shadowform Maintenance
        if i == 1 and menu.maintain_shadowform:get_state() and not has_shadowform and not is_moving then
            if not player:is_channelling_spell() then
                dbg("dps.sf", 2.0, "DPS: applying Shadowform")
                if cast_spell(spells.shadow_form, player, player) then return true end
            end
        end

        -- ========================================================================
        -- 2. CHANNELING / WANDING DETECTION (Don't Interrupt)
        -- ========================================================================

        local channel_id = player:get_active_channel_spell_id()
        local wanding_now = is_wanding_active(player)

        -- If wand is active, re-check thresholds — stop wand if conditions changed mid-fight
        if wanding_now then
            local wand_enabled = menu.use_wand and menu.use_wand:get_state()
            local mana_threshold = (menu.solo_dps_mana and menu.solo_dps_mana:get()) or 15
            local hp_threshold   = (menu.wand_target_hp and menu.wand_target_hp:get()) or 10
            local should_wand = wand_enabled and (mana_pct <= mana_threshold or target_hp_pct <= hp_threshold)

            if should_wand then
                dbg("dps.wand", 2.0, "DPS: wanding, letting it continue")
                return true
            else
                -- Thresholds no longer met → stop wand, let rotation cast spells
                stop_wand_if_active(player, target)
                dbg_now("DPS: wand stopped (thresholds changed)")
            end
        elseif channel_id and channel_id > 0 then
            -- Non-wand channel (e.g. Mind Flay) — don't interrupt
            dbg("dps.channel", 2.0, string.format("DPS: channeling spell %d", channel_id))
            return true
        end

        -- Try to START wand (moved up to prioritize over rotation when threshold is met)
        if try_use_wand(player, target, menu, target_hp_pct, mana_pct) then
            return true
        end

        -- ========================================================================
        -- 3. MANA SUSTAIN
        -- ========================================================================
        
        if menu.use_shadowfiend and menu.use_shadowfiend:get_state() then
            local threshold = (menu.shadowfiend_mana_threshold and menu.shadowfiend_mana_threshold:get()) or 30
            if mana_pct <= threshold then
                dbg("dps.sf", 1.0, string.format("DPS Shadowfiend: mana=%d%%", math.floor(mana_pct)))
                if cast_spell(spells.shadowfiend, target, player) then return true end
            end
        end

        -- ========================================================================
        -- 4. DoTs & DEBUFFS
        -- ========================================================================

        -- Vampiric Touch (Shadowform Only)
        if has_shadowform and menu.use_vampiric_touch and menu.use_vampiric_touch:get_state() then
            if not is_moving and target_hp_pct > 20 then
                if not target:debuff_up(spells.VT_DEBUFF_IDS) then
                    if (now - last_vt_cast) > 1200 then
                        dbg("dps.vt", 1.0, string.format("DPS VT: %s hp=%d%%", t_name, math.floor(target_hp_pct)))
                        if cast_spell(spells.vampiric_touch, target, player) then
                            last_vt_cast = now
                            return true
                        end
                    end
                end
            end
        end

        -- Shadow Word: Pain
        if target_hp_pct > 15 then
            if not target:debuff_up(spells.SWP_DEBUFF_IDS) then
                dbg("dps.swp", 1.0, string.format("DPS SWP: %s hp=%d%%", t_name, math.floor(target_hp_pct)))
                if cast_spell(spells.shadow_word_pain, target, player) then return true end
            end
        end

        -- Devouring Plague (If taught)
        if spells.devouring_plague and spells.devouring_plague:is_learned() then
            if target_hp_pct > 25 and not target:debuff_up(spells.DP_DEBUFF_IDS) then
                dbg("dps.dp", 1.0, string.format("DPS DP: %s hp=%d%%", t_name, math.floor(target_hp_pct)))
                if cast_spell(spells.devouring_plague, target, player) then return true end
            end
        end

        -- Vampiric Embrace (Self Heal / Support)
        if menu.use_vampiric_embrace and menu.use_vampiric_embrace:get_state() then
            if not target:debuff_up(spells.VE_DEBUFF_IDS) then
                dbg("dps.ve", 1.0, string.format("DPS VE: %s", t_name))
                if cast_spell(spells.vampiric_embrace, target, player) then return true end
            end
        end

        -- ========================================================================
        -- 5. BURST & EXECUTE
        -- ========================================================================
        
        -- Mind Blast (Always high priority filler/burst)
        if menu.use_mind_blast and menu.use_mind_blast:get_state() and not is_moving then
            -- Healer efficiency check: only Mind Blast if we have enough mana
            local heal_mana_threshold = (menu.mana_low_threshold and menu.mana_low_threshold:get()) or 20
            if mana_pct > heal_mana_threshold then
                dbg("dps.mb", 1.0, string.format("DPS Mind Blast: %s", t_name))
                if cast_spell(spells.mind_blast, target, player) then
                    return true
                end
            end
        end

        -- Shadow Word: Death (Execute)
        if menu.use_shadow_word_death and menu.use_shadow_word_death:get_state() then
            if target_hp_pct <= 25 then
                local min_hp = (menu.swd_min_hp and menu.swd_min_hp:get()) or 40
                if hp_pct >= min_hp then
                    dbg("dps.swd", 1.0, string.format("DPS SWD execute: %s hp=%d%% (self=%d%%)", t_name, math.floor(target_hp_pct), math.floor(hp_pct)))
                    if cast_spell(spells.shadow_word_death, target, player) then return true end
                end
            end
        end

        -- ========================================================================
        -- 6. FILLERS (Wand vs Mind Flay vs Racials)
        -- ========================================================================
        


        -- Mind Flay (Primary Shadow Filler - with channel guard & clip logic)
        if has_shadowform and not is_moving then
            -- Channel guard: if already channeling Mind Flay, handle clipping
            if player:is_channelling_spell() then
                local channel_id = 0
                pcall(function() channel_id = player:get_active_cast_or_channel_id() end)
                if channel_id == spells.mind_flay:id() then
                    local elapsed = 0
                    pcall(function() elapsed = player:get_channel_elapsed_ms() or 0 end)
                    -- Clip after 2nd tick (2000ms) if higher-priority spells need casting
                    if elapsed >= 2000 then
                        local vt_low = false
                        pcall(function() vt_low = target:debuff_remains(spells.vampiric_touch:id()) < 1.6 end)
                        local mb_ready = spells.mind_blast:is_learned() and spells.mind_blast:cooldown_up()
                        local swd_ready = spells.shadow_word_death:is_learned() and spells.shadow_word_death:cooldown_up()
                        if vt_low or mb_ready or swd_ready then
                            pcall(function() core.input.stop_casting() end)
                            dbg_now(string.format("DPS Mind Flay CLIPPED at %dms (vt=%s mb=%s swd=%s)",
                                elapsed, tostring(vt_low), tostring(mb_ready), tostring(swd_ready)))
                            return true
                        end
                    end
                    -- Still channeling, block other actions
                    return true
                end
            end
            -- Start new Mind Flay if not channeling
            if not player:is_channelling_spell() then
                stop_wand_if_active(player, target)
                if spells.mind_flay:is_learned() and spells.mind_flay:cooldown_up() then
                    dbg("dps.mf", 1.0, string.format("DPS Mind Flay: %s", t_name))
                    if spells.mind_flay:cast_safe(target) then
                        dbg_now(string.format("CAST OK: Mind Flay -> %s", t_name))
                        return true
                    end
                end
            end
        end

        -- Racial: Starshards (Night Elf)
        if not is_moving and cast_spell(spells.starshards, target, player) then
            return true
        end

        -- Pre-Shadowform Fillers (Holy Fire / Smite)
        if not has_shadowform and not is_moving then
            -- Holy Fire (Opener/Filler)
            if target_hp_pct > 30 then
                dbg("dps.hf", 1.0, string.format("DPS Holy Fire: %s hp=%d%%", t_name, math.floor(target_hp_pct)))
                if cast_spell(spells.holy_fire, target, player) then
                    return true
                end
            end
            -- Smite (Basic Filler)
            if spells.smite:is_learned() then
                -- Healer efficiency check: don't Smite if mana is low, ESPECIALLY if someone needs a heal
                local dps_mana_threshold = (menu.solo_dps_mana and menu.solo_dps_mana:get()) or 30
                local someone_needs_heal = GroupState.lowest_hp < 85

                -- Only Smite if mana is above threshold AND either nobody needs healing or mana is very healthy
                if (mana_pct > dps_mana_threshold) and (not someone_needs_heal or mana_pct > 70) then
                    dbg("dps.smite", 1.0, string.format("DPS Smite: %s (mana=%d%%)", t_name, math.floor(mana_pct)))
                    if cast_spell(spells.smite, target, player) then
                        return true
                    end
                else
                    dbg("dps.smite.skip", 2.0, string.format("DPS Smite SKIPPED: mana=%d%% (thresh=%d%%) needs_heal=%s", math.floor(mana_pct), dps_mana_threshold, tostring(someone_needs_heal)))
                end
            end
        end

        ::continue::
    end

    dbg("dps.idle", 3.0, "DPS: no action taken (end of loop)")
    return false
end

---Count enemies within a specific range of the player
---@param radius number
---@return number
local function count_enemies_in_range(radius)
    local me = izi.me()
    if not me then return 0 end
    
    -- Use izi.enemies() which is more reliable
    local enemies = izi.enemies(radius)
    if not enemies then return 0 end
    
    local count = 0
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy:is_valid() and safe_is_alive(enemy) then
            count = count + 1
        end
    end
    
    return count
end

---Handle emergency utility spells like Psychic Scream
---@param player game_object
---@param menu table
---@return boolean
local function handle_emergency_utility(player, menu)
    if not menu.use_psychic_scream:get_state() then
        return false
    end

    if not spells.psychic_scream:is_learned() then
        return false
    end
    
    -- Check if spell is on cooldown
    if not spells.psychic_scream:cooldown_up() then
        return false
    end

    local hp_pct = player:get_health_percentage()
    local hp_threshold = menu.scream_hp_threshold:get()
    local mob_threshold = menu.scream_mob_count:get()
    local enemies_in_8yd = count_enemies_in_range(8)

    -- Panic Condition: Low HP and at least 1 enemy close
    -- This is the PRIMARY fear trigger - based on YOUR health
    if hp_pct <= hp_threshold and enemies_in_8yd >= 1 then
        dbg_now(string.format("EMERGENCY Psychic Scream (PANIC): hp=%d%% enemies=%d", math.floor(hp_pct), enemies_in_8yd))
        if cast_spell(spells.psychic_scream, player, player) then
            core.log("Panic Fear! (HP: " .. math.floor(hp_pct) .. "% <= " .. hp_threshold .. "%)")
            return true
        end
    end

    -- AoE CC Condition: ONLY if there are MANY enemies (mob_threshold+ enemies)
    -- This should be a high threshold like 3+ to avoid triggering on normal pulls
    if mob_threshold >= 3 and enemies_in_8yd >= mob_threshold then
        dbg_now(string.format("EMERGENCY Psychic Scream (AOE): %d enemies >= %d threshold", enemies_in_8yd, mob_threshold))
        if cast_spell(spells.psychic_scream, player, player) then
            core.log("AoE Fear! (" .. enemies_in_8yd .. " enemies >= " .. mob_threshold .. ")")
            return true
        end
    end

    return false
end

-- ============================================================================
-- MAIN EXECUTE FUNCTION
-- ============================================================================

---@param local_player game_object
-- ============================================================================
-- PVP & UTILITY LOGIC
-- ============================================================================

local function get_focus_target()
    local ok, target = pcall(function()
        return izi.focus()
    end)
    return ok and target or nil
end

local function handle_pvp_logic(player, menu)
    if not menu.enable_pvp_mode:get_state() then
        return false
    end

    dbg("pvp.active", 5.0, "PvP mode active, evaluating PvP logic")
    local mana_pct = player:mana_pct()
    local focus = get_focus_target()
    local target = izi.target()

    -- 0. Mass Dispel Sniping (Immunity)
    if menu.mass_dispel_sniping and menu.mass_dispel_sniping:get_state() and spells.mass_dispel:is_learned() and spells.mass_dispel:cooldown_up() then
        local enemies = nil
        pcall(function() enemies = izi.enemies(30) end)
        if enemies then
            for _, e in ipairs(enemies) do
                if e and e:is_valid_enemy() then
                    -- 642 = Divine Shield, 1020 = Divine Shield, 498 = Divine Protection, 45438 = Ice Block
                    local immunity_ids = { 642, 1020, 498, 45438 }
                    for _, id in ipairs(immunity_ids) do
                        if e:buff_up(id) then
                            dbg_now("PvP Mass Dispel Sniping on " .. (e:get_name() or "?"))
                            if cast_spell(spells.mass_dispel, e, player) then return true end
                        end
                    end
                end
            end
        end
    end

    -- 1. SW:D CC Breaker (vs Poly/Fear)
    if menu.use_swd_breaker:get_state() and spells.shadow_word_death:is_learned() and spells.shadow_word_death:cooldown_up() then
        -- This logic usually requires scanning units targeting the player
        -- For simplicity, we check the current target/focus if they are casting CC on us
        local enemy_casters = {}
        if focus and focus:is_valid_enemy() then table.insert(enemy_casters, focus) end
        if target and target:is_valid_enemy() then table.insert(enemy_casters, target) end

        for _, enemy in __object_safety.live_ipairs(enemy_casters) do
            local is_casting = enemy:is_casting_spell()
            if is_casting then
                local e_target = nil
                pcall(function() e_target = enemy:get_target() end)
                if e_target and e_target:is_valid() and e_target:get_name() == player:get_name() then
                    local spell_id = enemy:get_active_spell_id()
                    -- Poly, Fear, Howl of Terror, Seduction, Repentance, Freezing Trap, Scatter Shot
                    local cc_ids = { 118, 12824, 12825, 12826, 28271, 28272, 5782, 6213, 6215, 5484, 17928, 6358, 20066, 14311, 19503 }
                    local is_cc = false
                    for _, id in ipairs(cc_ids) do if spell_id == id then is_cc = true break end end

                    if is_cc then
                        local cast_pct = enemy:get_cast_pct()
                        if cast_pct > 85 then
                            dbg_now(string.format("PvP SWD CC-break: spell=%d cast=%d%%", spell_id, math.floor(cast_pct)))
                            if cast_spell(spells.shadow_word_death, enemy, player) then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    -- 2. Offensive Dispel (Purge)
    if menu.use_offensive_dispel:get_state() and spells.dispel_magic:is_learned() then
        -- GATE: Skip offensive actions if group needs healing
        local heal_threshold = menu.heal_hp:get()
        if GroupState.lowest_hp < heal_threshold then
            goto skip_offensive_pvp
        end

        local purge_target = target
        if focus and focus:is_valid_enemy() then purge_target = focus end

        if purge_target and purge_target:is_valid_enemy() then
            -- Check for high priority buffs
            -- Lust, Hero, Innervate, PI, Ice Barrier, BoP, Fear Ward, Earth Shield, Divine Favor, Nature's Swiftness
            local high_priority_ids = { 2825, 32182, 29166, 10060, 10278, 1022, 6346, 974, 32594, 20216, 16188, 17116 }
            local should_purge = false
            
            for _, id in ipairs(high_priority_ids) do
                if purge_target:buff_up(id) then
                    should_purge = true
                    break
                end
            end

            if not should_purge and not menu.purge_high_priority_only:get_state() then
                -- Check for any magic buff
                if has_dispellable_magic_buff(purge_target) then
                    should_purge = true
                end
            end
            
            -- Prevent purging Lifebloom (33763) if target HP < 30% to avoid triggering the bloom heal
            if should_purge and purge_target:buff_up(33763) and purge_target:get_health_percentage() < 30 then
                should_purge = false
            end

            if should_purge then
                local p_name = ""
                pcall(function() p_name = purge_target:get_name() or "?" end)
                dbg_now(string.format("PvP Offensive Dispel: %s", p_name))
                if cast_spell(spells.dispel_magic, purge_target, player) then
                    return true
                end
            end
        end
    end

    -- 3. Mana Burn (Strategic)
    if menu.use_mana_burn:get_state() and spells.mana_burn:is_learned() and mana_pct > 30 then
        -- GATE: Skip offensive actions if group needs healing
        local heal_threshold = menu.heal_hp:get()
        if GroupState.lowest_hp < heal_threshold then
            goto skip_offensive_pvp
        end

        local burn_target = nil
        if focus and focus:is_valid_enemy() and focus:get_max_power(0) > 0 then
            burn_target = focus
        elseif not menu.mana_burn_focus_only:get_state() and target and target:is_valid_enemy() and target:get_max_power(0) > 0 then
            burn_target = target
        end

        if burn_target and (burn_target:mana_pct() or 0) > menu.mana_burn_target_mana:get() then
            if not player:is_moving() then
                local mb_name = ""
                pcall(function() mb_name = burn_target:get_name() or "?" end)
                dbg_now(string.format("PvP Mana Burn: %s (mana=%d%%)", mb_name, math.floor(burn_target:mana_pct() or 0)))
                if cast_spell(spells.mana_burn, burn_target, player) then
                    return true
                end
            end
        end
    end

    -- 3a. PvP SWP Multi-Dotting (Blackout Optimization)
    if menu.use_swp_multidot and menu.use_swp_multidot:get_state() and mana_pct > menu.swp_min_mana:get() then
        -- GATE: Skip offensive actions if group needs healing
        local heal_threshold = menu.heal_hp:get()
        if GroupState.lowest_hp < heal_threshold then
            goto skip_offensive_pvp
        end

        local enemies = nil
        pcall(function() enemies = izi.enemies(30) end)
        if enemies then
            local dot_count = 0
            local max_dots = menu.swp_max_targets:get()
            
            -- First count existing SWP dots on nearby enemies
            for _, e in ipairs(enemies) do
                if e and e:is_valid_enemy() and e:is_alive() then
                    if e:debuff_up(spells.SWP_DEBUFF_IDS) then
                        dot_count = dot_count + 1
                    end
                end
            end

            if dot_count < max_dots then
                for _, e in ipairs(enemies) do
                    if e and e:is_valid_enemy() and e:is_alive() and not e:debuff_up(spells.SWP_DEBUFF_IDS) then
                        local ok_immune, is_immune = pcall(function() 
                            return e.is_damage_immune and e:is_damage_immune(e.DMG.MAGICAL) 
                        end)
                        if not (ok_immune and is_immune == true) then
                            local e_name = ""
                            pcall(function() e_name = e:get_name() or "?" end)
                            dbg_now(string.format("PvP SWP Dotting for Blackout: %s", e_name))
                            if cast_spell(spells.shadow_word_pain, e, player) then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    ::skip_offensive_pvp::

    -- 4. Silence Focus (Shadow)
    if menu.use_silence_focus:get_state() and spells.silence and spells.silence:is_learned() and spells.silence:cooldown_up() then
        if focus and focus:is_valid_enemy() and focus:is_casting_spell() and focus:is_active_spell_interruptable() then
            local s_name = ""
            pcall(function() s_name = focus:get_name() or "?" end)
            dbg_now(string.format("PvP Silence: %s", s_name))
            if cast_spell(spells.silence, focus, player) then
                return true
            end
        end
    end

    -- 5. Pain Suppression on Stun
    if menu.use_pain_suppression_stun and menu.use_pain_suppression_stun:get_state() and spells.pain_suppression:is_learned() and spells.pain_suppression:cooldown_up() then
        local hp_pct = player:get_health_percentage()
        local is_stunned = false
        pcall(function() is_stunned = player:is_stunned() end)
        if hp_pct < 40 and is_stunned then
            dbg_now(string.format("PvP Pain Suppression on Stun (HP=%d%%)", math.floor(hp_pct)))
            if cast_spell(spells.pain_suppression, player, player) then return true end
        end
    end

    -- 6. Auto Totem Stomping
    if menu.auto_totem_stomping and menu.auto_totem_stomping:get_state() and spells.shoot:is_learned() and not player:is_moving() then
        local enemies = nil
        pcall(function() enemies = izi.enemies(30) end)
        if enemies then
            for _, e in ipairs(enemies) do
                if e and e:is_valid_enemy() then
                    local name = ""
                    pcall(function() name = e:get_name() or "" end)
                    if name and (string.match(name, "Tremor Totem") or string.match(name, "Grounding Totem") or string.match(name, "Cleansing Totem")) then
                        if cast_spell(spells.shoot, e, player) then
                            dbg_now("PvP Stomping Totem: " .. name)
                            return true
                        end
                    end
                end
            end
        end
    end

    -- 7. Auto Fear Ward
    if menu.use_fear_ward_auto and menu.use_fear_ward_auto:get_state() and spells.fear_ward:is_learned() and spells.fear_ward:cooldown_up() then
        if not player:buff_up(6346) then
            if cast_spell(spells.fear_ward, player, player) then
                dbg_now("PvP Auto Fear Ward")
                return true
            end
        end
    end

    return false
end

---@param local_player game_object
---@param menu table
---@param tick_tracker resource_ticks_tracker|nil
---@return boolean
function rotation_logic:execute(local_player, menu, tick_tracker)
    if not local_player then
        return false
    end

    -- Store menu ref for debug logging functions
    _active_menu_ref = menu

    -- Don't run rotation while ghost (e.g., at spirit healer after death)
    local ok_ghost, is_ghost = pcall(function()
        return local_player:is_ghost()
    end)
    if ok_ghost and is_ghost == true then
        return false
    end
    
    -- Don't run rotation while dead
    local ok_dead, is_dead = pcall(function()
        return local_player:is_dead()
    end)
    if ok_dead and is_dead == true then
        return false
    end
    
    local player = local_player
    
    -- Store tick tracker reference for mana optimization functions
    active_tick_tracker = tick_tracker
    
    -- Refresh entire group state ONCE per tick
    refresh_group_state(local_player, menu)
    
    -- Sync wand auto-attack state
    sync_wand_auto_active(player)
    
    -- Refresh spell data
    if spells and spells.refresh then
        spells:refresh()
    end
    
    -- Check if script is enabled
    if not menu.enable_script_check:get_state() then
        return false
    end

    -- Main Rotation Logic (Healing & DPS)
    -- Run if we are in combat OR if we need to heal
    
    -- DEFENSIVE / UTILITY (Emergency fear, etc.)
    if player:is_in_combat() then
        if handle_emergency_utility(player, menu) then
            return true
        end
    end

    -- ========================================================================
    -- SELF-PRESERVATION: Potions (checked before heal/DPS routing)
    -- ========================================================================
    if player:is_in_combat() then
        local hp_pct = player:get_health_percentage()
        local mana_pct = player:mana_pct()

        -- Health Potion
        if menu.use_hp_potions:get_state() then
            local hp_pot_threshold = menu.hp_potion_at:get()
            if hp_pct <= hp_pot_threshold then
                dbg_now(string.format("Self-Preservation Health Potion: HP=%.0f%% (threshold=%d%%)", hp_pct, hp_pot_threshold))
                if izi.use_best_health_potion_safe({ skip_casting = true }) then
                    return true
                end
            end
        end

        -- Mana Potion
        if menu.use_mana_potions:get_state() then
            local pot_threshold = menu.mana_potion_at:get()
            if mana_pct <= pot_threshold then
                dbg("exec.mana_pot", 2.0, string.format("Self-Preservation Mana Potion: mana=%d%% (threshold=%d%%)", math.floor(mana_pct), pot_threshold))
                if izi.use_best_mana_potion_safe({ skip_casting = true }) then
                    return true
                end
            end
        end
    end

    -- PvP Logic (SW:D breaker, purge, mana burn)
    -- This is now gated internally to prioritize healing if needed
    if handle_pvp_logic(player, menu) then
        return true
    end

    -- Global Shadowform Check
    local healing_only_mode = healing_only_enabled(menu)
    if not healing_only_mode and ensure_shadowform(player, menu) then
        return true
    end

    -- Out-of-Combat: Buffs and Attack on Target
    if not player:is_in_combat() then
        -- Attack on Target: Start DPS when enemy target is selected (even if not in combat)
        -- SKIP if Healing Only mode is enabled
        local healing_only_mode = healing_only_enabled(menu)
        if not healing_only_mode and menu.attack_on_target and menu.attack_on_target:get_state() then
            local target = get_current_target(player)
            if target and target:is_valid_enemy() and target:is_alive() then
                -- Valid enemy target selected - start DPS rotation to engage
                -- Pass the target directly to bypass TS (which may be empty out of combat)
                if handle_shadow_dps(player, menu, target) then
                    return true
                end
            end
        end
        
        -- Normal out of combat buffing
        if handle_out_of_combat(player, menu) then
            return true
        end
        
        -- Fallthrough to allow healing even if OOC
    end
    
    -- Main Rotation Logic (Healing & DPS)
    -- Run if we are in combat OR if we need to heal
    
    local support_healing_enabled = menu.enable_healing:get_state()
    local healing_only_mode = healing_only_enabled(menu)
    local has_shadowform = has_buff(player, spells.SHADOWFORM_BUFF_IDS)
    
    -- No Healing in Shadowform check
    local no_healing_in_shadowform = menu.no_healing_in_shadowform and menu.no_healing_in_shadowform:get_state()
    if has_shadowform and no_healing_in_shadowform then
        support_healing_enabled = false
         healing_only_mode = false -- Can't be healing only if healing is forbidden
    end
    
    if healing_only_mode then
        -- HEALING ONLY: Only do healing, no DPS at all
        -- (Safe to run OOC as items are gated by is_in_combat check now)
        dbg("exec.route", 3.0, "Route: HEALING_ONLY mode")
        if handle_in_combat(player, menu) then
            return true
        end
        return false
    end

    -- Normal mode: Check if we're solo or group is healthy -> prioritize DPS
    local is_solo = #GroupState.members <= 1
    local all_healthy = true

    if not is_solo then
        -- Only check group health if support healing is enabled AND we are not in Shadowform
        -- (Shadow priests usually prioritize DPS unless the group is critically low)
        local health_threshold = menu.solo_dps_group_hp:get()
        if support_healing_enabled then
            if GroupState.lowest_hp < health_threshold then
                all_healthy = false
            end
        end
    end

    dbg("exec.route", 3.0, string.format("Route: solo=%s healthy=%s combat=%s shadow=%s heal_enabled=%s",
        tostring(is_solo), tostring(all_healthy), tostring(player:is_in_combat()),
        tostring(has_shadowform), tostring(support_healing_enabled)))

    -- SOLO or GROUP HEALTHY: Do DPS first, then check for healing
    -- Only DPS if we are actually in combat (to prevent pulling while OOC unless manually targeted)
    if player:is_in_combat() and (is_solo or all_healthy) then
        if handle_shadow_dps(player, menu) then
            return true
        end
    end

    -- GROUP NEEDS HEALING (or fallback from DPS): Heal first
    if support_healing_enabled then
        -- Skip healing fallback when group is healthy and nobody is below stop threshold
        local stop_hp = menu.stop_healing_hp:get()
        if not all_healthy or GroupState.lowest_hp < stop_hp then
            if handle_in_combat(player, menu) then
                return true
            end
        end
    end

    -- Fallback: Try DPS if nothing else to do and we are in combat
    if player:is_in_combat() then
        if handle_shadow_dps(player, menu) then
            return true
        end
    end

    return false
end

-- Export utility functions for external use
rotation_logic.is_5sr_active = is_5sr_active
rotation_logic.get_5sr_remaining_ms = get_5sr_remaining_ms
rotation_logic.get_ms_to_mana_tick = get_ms_to_mana_tick

return rotation_logic
