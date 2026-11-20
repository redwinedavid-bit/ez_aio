local __object_safety=require("shared/object_safety")
-- ============================================================================
local performance = require("shared/rotation_performance")
-- Shaman Restoration Rotation AIO (Classic ERA)
-- Action Priority List for Restoration Healer + Leveling Support
-- ============================================================================

local rotation_logic = {}

---@type enums
local enums = require("common/enums")

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type spell_helper
local spell_helper = require("common/utility/spell_helper")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

-- Import spells
local spells = require("rotations/shaman/era/spells")

-- ============================================================================
-- STATE TRACKING
-- ============================================================================

local last_buff_check = 0
local BUFF_CHECK_INTERVAL_MS = 5000

local last_dispel_check = 0
local DISPEL_CHECK_INTERVAL_MS = 1000

local last_purge_check = 0
local PURGE_CHECK_INTERVAL_MS = 1500 -- GCD based throttle

local last_heal_cast = 0
local HEAL_THROTTLE_MS = 100

local last_totem_cast = 0
local TOTEM_COOLDOWN_MS = 1000

local last_natures_swiftness_use = 0
local NATURES_SWIFTNESS_THROTTLE_MS = 1000

-- Totem twisting state
local last_windfury_totem_cast = 0
local WINDFURY_TOTEM_DURATION_MS = 120000 -- 2 minutes
local WINDFURY_BUFF_DURATION_MS = 9000 -- 9 seconds

local last_weapon_buff_cast = 0

-- Target tracking for engagement
local last_target_guid = nil

-- Reference to the tick tracker (passed from main.lua)
local active_tick_tracker = nil

-- Specialization
local current_spec = "Unknown"
local last_spec_check = 0
local SPEC_CHECK_INTERVAL_MS = 30000 -- Check every 30s or on level up

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

---Check if player has enough mana
---@param player game_object
---@param min_mana_pct number
---@return boolean
local function has_enough_mana(player, min_mana_pct)
    return player:mana_pct() >= min_mana_pct
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

---Check if unit needs dispel
---@param unit game_object
---@return boolean
local function needs_dispel(unit)
    if not unit or not unit:is_alive() or not unit.get_debuffs then
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
        if dtype == "Poison" then
            target_type = enums.buff_type.POISON
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

---Check if unit needs poison cure
---@param unit game_object
---@return boolean
local function needs_poison_cure(unit)
    if not unit or not unit:is_alive() or not unit.get_debuffs then
        return false
    end
    
    local ok, debuffs = pcall(function()
        return unit:get_debuffs()
    end)
    if not ok or type(debuffs) ~= "table" then
        return false
    end
    
    for _, debuff in ipairs(debuffs) do
        -- Check for Enum (if verified) or standardized type ID
        -- Classic/TBC: Poison is usually type 4 or string "Poison"
        if debuff then
             if debuff.type == enums.buff_type.POISON or debuff.type == "Poison" or debuff.type == 4 then
                return true
             end
        end
    end
    return false
end

---Check if unit needs disease cure
---@param unit game_object
---@return boolean
local function needs_disease_cure(unit)
    if not unit or not unit:is_alive() or not unit.get_debuffs then
        return false
    end
    
    local ok, debuffs = pcall(function()
        return unit:get_debuffs()
    end)
    if not ok or type(debuffs) ~= "table" then
        return false
    end
    
    for _, debuff in ipairs(debuffs) do
        -- Classic/TBC: Disease is usually type 3 or string "Disease"
        if debuff then
            if debuff.type == enums.buff_type.DISEASE or debuff.type == "Disease" or debuff.type == 3 then
                return true
            end
        end
    end
    return false
end

---Check if unit has a purgeable (Magic) buff
---@param unit game_object
---@return boolean
local function has_purgeable_buff(unit)
    if not unit or not unit:is_alive() or not unit.is_purgable then
        return false
    end
    
    local ok, output = pcall(function()
        return unit:is_purgable()
    end)
    
    if ok and output and output.is_purgeable == true then
        -- The SDK says it is purgeable.
        -- We can double check if there's actually a table of buffs
        if type(output.table) == "table" and #output.table > 0 then
            return true
        end
    end

    return false
end

---Detect current specialization based on learned talents
---@return string "Elemental" | "Enhancement" | "Restoration" | "Leveling" | "Unknown"
local function detect_spec()
    local now = core.game_time()
    if (now - last_spec_check) < SPEC_CHECK_INTERVAL_MS and current_spec ~= "Unknown" then
        return current_spec
    end

    last_spec_check = now

    -- Restoration Check (Mana Tide or Nature's Swiftness)
    if (spells.mana_tide_totem and spells.mana_tide_totem:is_learned())
        or (spells.natures_swiftness and spells.natures_swiftness:is_learned())
    then
        current_spec = "Restoration"
        return current_spec
    end

    -- Enhancement Check (Stormstrike)
    if spells.stormstrike and spells.stormstrike:is_learned() then
        current_spec = "Enhancement"
        return current_spec
    end

    -- Elemental Check (Totem of Wrath - TBC)
    if spells.totem_of_wrath and spells.totem_of_wrath:is_learned() then
        current_spec = "Elemental"
        return current_spec
    end

    -- Leveling / Default
    current_spec = "Leveling"

    core.log(string.format("[BxA AIO] Shaman Spec Detected: %s", current_spec))
    return current_spec
end

---Get party/raid members safely
---@param player game_object
---@return table
local function get_group_members(player)
    local members = {}

    -- Try Party members in range (40y, incl. self)
    local ok_range, party_range = pcall(function()
        return performance:get_unit_list(player, "get_party_members_in_range", 40, true)
    end)
    if ok_range and party_range and #party_range > 0 then
        return party_range
    end

    -- Fallback: normal Party members
    local ok_party, party = pcall(function()
        return performance:get_unit_list(player, "get_party_members")
    end)
    if ok_party and party and #party > 0 then
        return party
    end

    -- Solo – return player only
    table.insert(members, player)
    return members
end

---Find the lowest HP ally
---@param player game_object
---@param min_hp_pct number (optional) minimum HP% to consider (default: 0)
---@return game_object|nil, number
local function find_lowest_hp_ally(player, min_hp_pct)
    min_hp_pct = min_hp_pct or 0
    local group = get_group_members(player)
    local lowest_ally = nil
    local lowest_hp = 101
    
    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() then
            local hp = ally:get_health_percentage() or 100
            if hp < lowest_hp and hp >= min_hp_pct then
                lowest_hp = hp
                lowest_ally = ally
            end
        end
    end
    
    -- Check player too
    local player_hp = player:get_health_percentage() or 100
    if player_hp < lowest_hp and player_hp >= min_hp_pct then
        lowest_hp = player_hp
        lowest_ally = player
    end
    
    return lowest_ally, lowest_hp
end

---Calculate health deficit
---@param unit game_object
---@return number
local function get_unit_deficit(unit)
    if not unit then return 0 end
    local hp = unit:get_health() or 0
    local hp_pct = unit:get_health_percentage() or 100
    if hp_pct >= 100 or hp_pct <= 0 then return 0 end
    local max_hp = (hp * 100) / hp_pct
    return math.max(0, max_hp - hp)
end

---Find tank (first warrior/paladin/druid in group, or main assist)
---@param player game_object
---@return game_object|nil
local function find_tank(player)
    local group = get_group_members(player)
    
    -- Priority: Look for warrior, then paladin, then druid
    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() then
            local class = ally:get_class()
            if class == enums.class_id.WARRIOR then
                return ally
            end
        end
    end
    
    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() then
            local class = ally:get_class()
            if class == enums.class_id.PALADIN then
                return ally
            end
        end
    end
    
    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() then
            local class = ally:get_class()
            if class == enums.class_id.DRUID then
                return ally
            end
        end
    end
    
    -- Fallback: return player
    return player
end

---Count allies below HP threshold
---@param player game_object
---@param hp_threshold number
---@return number
local function count_allies_below_hp(player, hp_threshold)
    local group = get_group_members(player)
    local count = 0
    
    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() then
            local hp = ally:get_health_percentage() or 100
            if hp < hp_threshold then
                count = count + 1
            end
        end
    end
    
    return count
end

---Check if player is in a group (party or raid)
---@param player game_object
---@return boolean
local function is_in_group(player)
    -- Try is_in_party first
    local ok_party, in_party = pcall(function()
        return player:is_in_party()
    end)
    if ok_party and in_party then
        return true
    end
    
    -- Try is_in_raid
    local ok_raid, in_raid = pcall(function()
        return player:is_in_raid()
    end)
    if ok_raid and in_raid then
        return true
    end
    
    -- Fallback: check if get_party_members_in_range returns anyone else
    local ok, party = pcall(function()
        return performance:get_unit_list(player, "get_party_members_in_range", 40, false)  -- false = don't include self
    end)
    if ok and party and #party > 0 then
        return true
    end
    
    return false
end

-- ============================================================================
-- MANA TICK / 5SR OPTIMIZATION
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
-- BUFF CONSTANTS
-- ============================================================================

-- LIGHTNING_SHIELD_IDS is no longer needed as spells.lua handles it via track_buff

-- ============================================================================
-- SPELL CASTING HELPERS
-- ============================================================================

---Cast a healing spell with throttle protection
---@param spell table The spell object from izi.spell()
---@param target game_object The target to heal
---@param rank number|nil Optional rank for logging
---@return boolean success True if cast was attempted
local function cast_heal(spell, target, rank)
    if not spell or not target then return false end
    
    if (core.game_time() - last_heal_cast) < HEAL_THROTTLE_MS then
        return false
    end

    if spell:is_castable({ skip_facing = true }) and spell:cast(target) then
        last_heal_cast = core.game_time()
        
        local rank_str = rank and (" (Rank " .. tostring(rank) .. ")") or ""
        
        -- Safe target name resolution
        local t_name = "Ally"
        pcall(function() 
            if target and target.get_name then
                t_name = target:get_name() or "Ally"
            end
        end)
        
        -- Safe spell name resolution (hardcoded fallbacks for Shaman spells)
        local s_name = "Heal"
        if spell == spells.healing_wave or (rank and spells.hw_ranks and spells.hw_ranks[rank] == spell) then
            s_name = "Healing Wave"
        elseif spell == spells.lesser_healing_wave or (rank and spells.lhw_ranks and spells.lhw_ranks[rank] == spell) then
            s_name = "Lesser Healing Wave"
        elseif spell == spells.chain_heal then
            s_name = "Chain Heal"
        else
            -- Check for name property if it's none of the above
            pcall(function()
                if spell.get_name then s_name = spell:get_name()
                elseif spell.name then s_name = spell.name
                end
            end)
        end

        core.log(string.format("[BxA AIO] Healing: %s on %s%s", s_name, t_name, rank_str))
        return true
    end
    return false
end

---Select the optimal Healing Wave rank based on target health deficit and TBC penalty rules
---@param player game_object
---@param target game_object
---@param menu table
---@return any The spell object to cast
local function get_smart_healing_wave(player, target, menu)
    -- If smart downranking is disabled, just return the highest rank wrapper
    if not menu.enable_smart_downranking:get_state() then
        return spells.healing_wave
    end

    local deficit = target:get_max_health() - target:get_health()
    local player_level = player:get_level()
    local avoid_penalty = menu.downrank_penalty_prevention:get_state()

    local best_fallback = spells.healing_wave
    local best_rank = nil
    
    -- Iterate in reverse (lowest level rank first)
    for i = #spells.HEALING_WAVE_RANKS, 1, -1 do
        local rank_data = spells.HEALING_WAVE_RANKS[i]
        local spell_object = spells.hw_ranks[rank_data.rank]
        
        if spell_object and spell_object:is_learned() then
            -- TBC Penalty check: Spells learned 10+ levels below player level
            local has_penalty = rank_data.level < (player_level - 10)
            
            if not (avoid_penalty and has_penalty) then
                if rank_data.heal >= (deficit * 0.9) then
                    return spell_object, rank_data.rank
                end
                best_fallback = spell_object
                best_rank = rank_data.rank
            end
        end
    end

    return best_fallback, best_rank
end

---Select the optimal Lesser Healing Wave rank based on target health deficit and TBC penalty rules
---@param player game_object
---@param target game_object
---@param menu table
---@return any The spell object to cast
local function get_smart_lesser_healing_wave(player, target, menu)
    -- If smart downranking is disabled, just return the highest rank wrapper
    if not menu.enable_smart_downranking:get_state() then
        return spells.lesser_healing_wave
    end

    local deficit = target:get_max_health() - target:get_health()
    local player_level = player:get_level()
    local avoid_penalty = menu.downrank_penalty_prevention:get_state()

    local best_fallback = spells.lesser_healing_wave
    local best_rank = nil
    
    -- Iterate in reverse (lowest level rank first)
    for i = #spells.LESSER_HEALING_WAVE_RANKS, 1, -1 do
        local rank_data = spells.LESSER_HEALING_WAVE_RANKS[i]
        local spell_object = spells.lhw_ranks[rank_data.rank]
        
        if spell_object and spell_object:is_learned() then
            -- TBC Penalty check
            local has_penalty = rank_data.level < (player_level - 10)
            
            if not (avoid_penalty and has_penalty) then
                if rank_data.heal >= (deficit * 0.9) then
                    return spell_object, rank_data.rank
                end
                best_fallback = spell_object
                best_rank = rank_data.rank
            end
        end
    end

    return best_fallback, best_rank
end



-- ============================================================================
-- TOTEM MANAGEMENT
-- ============================================================================

---Check if a totem is currently active
---@param player game_object
---@param totem_name string
---@return boolean
local function is_totem_active(player, totem_name)
    -- This is a simplified check - in reality you'd need to track totems
    -- For now, we'll use a cooldown-based approach
    return false
end

---Place a totem if not on cooldown
---@param spell table
---@param player game_object
---@return boolean
local function place_totem(spell, player)
    local now = core.game_time()
    if (now - last_totem_cast) < TOTEM_COOLDOWN_MS then
        return false
    end
    
    if spell:is_learned() then
        if spell:is_castable({ skip_facing = true }) and spell:cast(player) then
            last_totem_cast = now
            return true
        end
    end
    return false
end

-- ============================================================================
-- OUT-OF-COMBAT LOGIC (BUFFS & TOTEMS)
-- ============================================================================

---Check if 5-Second Rule is currently active
---@return boolean
-- ============================================================================
-- BUFF & MAINTENANCE HANDLERS
-- ============================================================================

local function handle_shield_buffs(player, menu)
    local now = core.game_time()
    
    -- Add secondary throttle for safety
    if (now - last_buff_check) < 1000 then 
        return false 
    end
    
    -- Lightning Shield (Secondary / Enhancement)
    if menu.use_lightning_shield and menu.use_lightning_shield:get_state() then


        if spells.lightning_shield:is_learned() and has_enough_mana(player, 10) then
            local buff_data = buff_manager:get_buff_data(player, spells.LIGHTNING_SHIELD_BUFF_IDS)
            if not buff_data.is_active or buff_data.stacks == 0 then
                if spells.lightning_shield:is_castable({ skip_facing = true }) and spells.lightning_shield:cast(player) then
                    last_buff_check = now -- Update throttle
                    core.log("[BxA AIO] Maintenance: Casting Lightning Shield")
                    return true
                end
            end
        end
    end
    
    return false
end

local function handle_earth_shield(player, menu)
    local now = core.game_time()
    
    -- Throttled check
    if (now - last_buff_check) < 1000 then 
        return false 
    end
    
    if not menu.use_earth_shield or not menu.use_earth_shield:get_state() then
        return false
    end
    
    if not spells.earth_shield:is_learned() then
        return false
    end
    
    local tank = find_tank(player)
    if tank and tank:is_alive() then
        -- Check if tank has Earth Shield (from us)
        -- Note: Checking specific Earth Shield buff ID
        local buff_data = buff_manager:get_buff_data(tank, spells.EARTH_SHIELD_BUFF_IDS)
        
        if spells.earth_shield:is_learned() then
            -- Check if tank has Earth Shield (from us)
            local buff_data = buff_manager:get_buff_data(tank, spells.EARTH_SHIELD_BUFF_IDS)
            
            -- Refresh if missing or low stacks (< 2)
            if not buff_data.is_active or buff_data.stacks < 2 then
                 if spells.earth_shield:is_castable() and spells.earth_shield:cast(tank) then
                    last_buff_check = now -- Update throttle
                    return true
                end
            end
        end
    end
    return false
end

-- ============================================================================
-- OUT OF COMBAT LOGIC
-- ============================================================================

---@param player game_object
---@param menu table
---@return boolean
local function handle_out_of_combat(player, menu)
    local now = core.game_time()
    
    -- Skip if casting
    if player:is_channeling() or player:is_casting() then
        return false
    end
    
    -- Check buffs periodically
    if now - last_buff_check < BUFF_CHECK_INTERVAL_MS then
        return false
    end
    last_buff_check = now
    
    -- Minimum mana requirement for buffing
    if not has_enough_mana(player, 20) then
        return false
    end
    
    -- Shield Buffs (Water Shield > Lightning Shield)
    if handle_shield_buffs(player, menu) then
        return true
    end
    
    -- Weapon Buff (only cast every 5 minutes to prevent spam)
    if menu.use_weapon_buff and menu.use_weapon_buff:get_state() then
        local weapon_buff_type = menu.weapon_buff_type and menu.weapon_buff_type:get() or 1
        local weapon_spell = nil
        
        if weapon_buff_type == 1 then -- Rockbiter
            weapon_spell = spells.rockbiter_weapon
        elseif weapon_buff_type == 2 then -- Flametongue
            weapon_spell = spells.flametongue_weapon
        elseif weapon_buff_type == 3 then -- Frostbrand
            weapon_spell = spells.frostbrand_weapon
        elseif weapon_buff_type == 4 then -- Windfury
            weapon_spell = spells.windfury_weapon
        end
        
        -- Only cast weapon buff every 5 minutes (300 seconds)
        if weapon_spell and weapon_spell:is_learned() then
            if (now - last_weapon_buff_cast) >= 300000 then  -- 5 minute throttle
                if weapon_spell:is_castable({ skip_facing = true }) and weapon_spell:cast(player) then
                    last_weapon_buff_cast = now
                    return true
                end
            end
        end
    end
    
    return false
end

-- ============================================================================
-- HEALING LOGIC (GROUP & SOLO)
-- ============================================================================

---@param player game_object
---@param menu table
---@return boolean
local function handle_healing(player, menu)
    local now = core.game_time()
    
    -- Skip if casting (allow channel check for specific spells)
    if player:is_casting() then
        return false
    end
    
    -- Safety throttle to prevent double casting due to latency
    if (now - last_heal_cast) < 250 then
        return false
    end
    
    local hp_pct = player:get_health_percentage()
    local mana_pct = player:mana_pct()
    local is_moving = player:is_moving()
    
    -- Get menu thresholds
    local tank_emergency_hp = menu.tank_emergency_hp:get()
    local player_emergency_hp = menu.player_emergency_hp:get()
    local lesser_healing_wave_hp = menu.lesser_healing_wave_hp:get()
    local healing_wave_hp = menu.healing_wave_hp:get()
    local chain_heal_hp = menu.chain_heal_hp:get()
    local aoe_threshold = menu.group_aoe_threshold:get()
    local aoe_hp = menu.aoe_hp_threshold:get()
    local mana_low = menu.mana_low_threshold:get()

    -- HOISTED TARGETS (Global to this function scope)
    local lowest_ally, lowest_hp = find_lowest_hp_ally(player, 0)
    local tank = find_tank(player)
    local tank_hp = tank and tank:get_health_percentage() or 100
    
    
    -- DEBUG: Print threshold values and current HP
    -- if lowest_ally then
    --     core.log("[SHAMAN DEBUG] lowest_hp=" .. tostring(lowest_hp) .. "%, healing_wave_hp=" .. tostring(healing_wave_hp) .. "%, lesser_healing_wave_hp=" .. tostring(lesser_healing_wave_hp) .. "%, player_emergency_hp=" .. tostring(player_emergency_hp) .. "%")
    -- end
    
    -- ========================================================================
    -- PRIORITY 0: Emergency Self-Healing (Ignore Group)
    -- ========================================================================
    if hp_pct <= player_emergency_hp then
        if not is_moving and has_enough_mana(player, 10) then
            local lhw_spell, lhw_rank = get_smart_lesser_healing_wave(player, player, menu)
            if lhw_spell and lhw_spell:is_learned() then
                if cast_heal(lhw_spell, player, lhw_rank) then
                    return true
                end
            else
                local hw_spell, hw_rank = get_smart_healing_wave(player, player, menu)
                if hw_spell and hw_spell:is_learned() then
                    if cast_heal(hw_spell, player, hw_rank) then
                        return true
                    end
                end
            end
        end
    end

    -- PRIORITY 1: Maintenance (Shields)
    -- ========================================================================
    if handle_earth_shield(player, menu) then
        return true
    end
    if handle_shield_buffs(player, menu) then
        return true
    end




    -- ========================================================================
    -- PRIORITY 2: Dispels (Purify / Purge)
    -- ========================================================================
    -- ========================================================================
    -- PRIORITY 2: Dispels (Poison / Disease)
    -- ========================================================================
    if menu.use_dispel:get_state() then
        if (now - last_dispel_check) >= 1000 then -- Throttle to 1s
            last_dispel_check = now
            
            local handled = false
            
            -- Check self first
            if not handled and spells.cure_poison:is_learned() and needs_poison_cure(player) then
                 if spells.cure_poison:is_castable({ skip_facing = true }) and spells.cure_poison:cast(player) then handled = true return true end
            end
            if not handled and spells.cure_disease:is_learned() and needs_disease_cure(player) then
                 if spells.cure_disease:is_castable({ skip_facing = true }) and spells.cure_disease:cast(player) then handled = true return true end
            end
            
            -- Check group
            if not handled then
                local group = get_group_members(player)
                for _, member in ipairs(group) do
                    if not handled and member and member:is_alive() then
                        -- Check distance (Cure Poison range is 40yd)
                        if member:distance() <= 40 then
                            if spells.cure_poison:is_learned() and needs_poison_cure(member) then
                                if spells.cure_poison:is_castable() and spells.cure_poison:cast(member) then handled = true return true end
                            end
                            if spells.cure_disease:is_learned() and needs_disease_cure(member) then
                                if spells.cure_disease:is_castable() and spells.cure_disease:cast(member) then handled = true return true end
                            end
                        end
                    end
                end
            end
        end
    end
    
    if menu.use_purge and menu.use_purge:get_state() then
        if (now - last_purge_check) >= PURGE_CHECK_INTERVAL_MS then
             -- Purge Enemy Magic
             local target = izi.target()
             if target and target:is_alive() and player:can_attack(target) then
                 if spells.purge:is_learned() and spells.purge:cooldown_up() and has_enough_mana(player, 10) then
                      -- INTELLIGENT CHECK: Only purge if target has magic buffs according to SDK
                      if has_purgeable_buff(target) then
                           if spells.purge:is_castable() and spells.purge:cast(target) then 
                               last_purge_check = now
                               return true 
                           end
                      end
                 end
             end
        end
    end

    -- ========================================================================
    -- PRIORITY 3: Nature's Swiftness Emergency
    -- ========================================================================
    if menu.use_natures_swiftness:get_state() then
        local ns_hp_threshold = menu.natures_swiftness_hp:get()
        
        -- Check tank emergency
        if tank and tank:is_alive() then
            if tank_hp <= ns_hp_threshold then
                if spells.natures_swiftness:is_learned() then
                    if (now - last_natures_swiftness_use) > NATURES_SWIFTNESS_THROTTLE_MS then
                        if spells.natures_swiftness:is_castable({ skip_facing = true }) and spells.natures_swiftness:cast(player) then
                            last_natures_swiftness_use = now
                            -- Immediately follow with max rank Healing Wave
                            if spells.healing_wave:is_learned() then
                                if cast_heal(spells.healing_wave, tank) then
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
        
        -- Check any ally emergency
        if lowest_ally and lowest_hp <= ns_hp_threshold then
            if spells.natures_swiftness:is_learned() then
                if (now - last_natures_swiftness_use) > NATURES_SWIFTNESS_THROTTLE_MS then
                    if spells.natures_swiftness:is_castable({ skip_facing = true }) and spells.natures_swiftness:cast(player) then
                        last_natures_swiftness_use = now
                        -- Immediately follow with max rank Healing Wave
                        if spells.healing_wave:is_learned() then
                            if cast_heal(spells.healing_wave, lowest_ally) then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 2: Self Emergency (Health Potion)
    -- ========================================================================
    
    if menu.use_hp_potions:get_state() then
        if hp_pct <= menu.hp_potion_at:get() then
            if izi.use_best_health_potion_safe() then
                return true
            end
        end
    end
    
    -- ========================================================================
    -- HEALING LOGIC SPLIT (Dungeon vs Raid)
    -- ========================================================================
    local healing_mode = menu.healing_mode:get() -- 1=Auto, 2=Dungeon, 3=Raid
    if healing_mode == 1 then
        -- Auto: Assume Raid if > 5 members
        if #get_group_members(player) > 5 then healing_mode = 3 else healing_mode = 2 end
    end

    if healing_mode == 3 then
        -- RAID MODE: CHAIN HEAL PRIORITY
        if menu.enable_chain_heal and menu.enable_chain_heal:get_state() and not is_moving then
             local low_count = count_allies_below_hp(player, aoe_hp)
             -- Use Chain Heal if at least 2 people are low (aggressive)
             if low_count >= 2 and spells.chain_heal:is_learned() and has_enough_mana(player, 25) then
                  if lowest_ally then
                      if cast_heal(spells.chain_heal, lowest_ally) then return true end
                  end
             end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 3: Tank Emergency Healing
    -- ========================================================================
    
    if tank and tank:is_alive() and tank_hp <= tank_emergency_hp then
        -- ... (Existing Tank Emergency Logic)
        if not is_moving and has_enough_mana(player, 15) then
            local lhw_spell, lhw_rank = get_smart_lesser_healing_wave(player, tank, menu)
            if lhw_spell and lhw_spell:is_learned() then
                if cast_heal(lhw_spell, tank, lhw_rank) then return true end
            end
        end
        
        if not is_moving and has_enough_mana(player, 20) then
            local hw_spell, hw_rank = get_smart_healing_wave(player, tank, menu)
            if hw_spell and hw_spell:is_learned() then
                 if cast_heal(hw_spell, tank, hw_rank) then return true end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 4: Tank Standard Healing (Efficient Downranking)
    -- ========================================================================
    
    if tank and tank:is_alive() and tank_hp <= healing_wave_hp then
         -- In Dungeon Mode, we prioritize keeping the tank topped efficiently
         if not is_moving and has_enough_mana(player, 20) then
             local hw_spell, hw_rank = get_smart_healing_wave(player, tank, menu)
             if hw_spell and hw_spell:is_learned() then
                 if cast_heal(hw_spell, tank, hw_rank) then return true end
             end
         end
    end

    -- ========================================================================
    -- PRIORITY 5: Raid/Party AoE Healing (if not covered by Raid Mode above)
    -- ========================================================================
    if healing_mode == 2 then
        -- DUNGEON MODE: CHAIN HEAL CONSERVATIVE
        if menu.enable_chain_heal and menu.enable_chain_heal:get_state() and not is_moving then
            local low_count = count_allies_below_hp(player, aoe_hp)
            if low_count >= aoe_threshold and spells.chain_heal:is_learned() and has_enough_mana(player, 30) then
                if lowest_ally then
                    if spells.chain_heal:is_castable() and spells.chain_heal:cast(lowest_ally) then
                        last_heal_cast = core.game_time()
                        return true
                    end
                end
            end
        end
    end
    -- ========================================================================
    -- PRIORITY 7: Lesser Healing Wave (Medium Emergency)
    -- ========================================================================
    
    if lowest_ally and lowest_hp <= lesser_healing_wave_hp then
        if not is_moving and has_enough_mana(player, 15) then
            local lhw_spell, lhw_rank = get_smart_lesser_healing_wave(player, lowest_ally, menu)
            if lhw_spell and lhw_spell:is_learned() then
                if cast_heal(lhw_spell, lowest_ally, lhw_rank) then return true end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 8: Dispel / Cleanse
    -- ========================================================================
    
    if menu.use_dispel:get_state() then
        if (now - last_dispel_check) >= DISPEL_CHECK_INTERVAL_MS then
            last_dispel_check = now
            
            local group = get_group_members(player)
            
            for _, ally in __object_safety.live_ipairs(group) do
                if ally and ally:is_alive() then
                    -- Poison Cure
                    if needs_poison_cure(ally) then
                        if spells.cure_poison:is_learned() then
                            if spells.cure_poison:is_castable() and spells.cure_poison:cast(ally) then
                                return true
                            end
                        end
                    end
                    
                    -- Disease Cure
                    if needs_disease_cure(ally) then
                        if spells.cure_disease:is_learned() then
                            if spells.cure_disease:is_castable() and spells.cure_disease:cast(ally) then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 9: Lightning Shield Refresh (Combat)
    -- ========================================================================
    
    -- Maintain Lightning Shield (Combat) - Using buff_manager as per official docs
    if menu.use_lightning_shield and menu.use_lightning_shield:get_state() then
        if spells.lightning_shield:is_learned() and has_enough_mana(player, 10) then
            local buff_data = buff_manager:get_buff_data(player, spells.LIGHTNING_SHIELD_BUFF_IDS)
            if not buff_data.is_active or buff_data.stacks == 0 then
                if spells.lightning_shield:is_castable({ skip_facing = true }) and spells.lightning_shield:cast(player) then
                    last_lightning_shield_cast = core.game_time()
                    return true
                end
            end
        end
    end

    -- ========================================================================
    -- PRIORITY 9: Healing Wave (Efficient Healing with 5SR Optimization)
    -- ========================================================================
    
    if lowest_ally and lowest_hp <= healing_wave_hp then
        
        if not is_moving then
            -- 5SR Optimization
            local is_urgent = lowest_hp <= player_emergency_hp
            
            -- Mana tick optimization
            if not is_urgent and should_wait_for_mana_tick(player, 400) then
                return true
            end
            
            if has_enough_mana(player, 1) then
                local hw_spell = get_smart_healing_wave(player, lowest_ally, menu)
                if hw_spell and hw_spell:is_learned() then
                    if cast_heal(hw_spell, lowest_ally) then return true end
                end
            end
        end
    end
    
    -- ========================================================================
    -- MANA TIDE PANIC / FORCE (Priority Early)
    -- ========================================================================
    if menu.mana_tide_panic_key:get_state() then
        if place_totem(spells.mana_tide_totem, player) then
            return true
        end
    end

    -- ========================================================================
    -- PRIORITY 10: Mana Tide Totem (Auto)
    -- ========================================================================
    if menu.use_mana_tide_totem and menu.use_mana_tide_totem:get_state() then
        local mana_tide_threshold = menu.mana_tide_group_mana:get()
        local min_players = menu.mana_tide_min_players:get()
        
        -- Check if group needs mana
        local group = get_group_members(player)
        local low_mana_count = 0
        
        for _, ally in __object_safety.live_ipairs(group) do
            if ally and ally:is_alive() then
                local ally_mana = ally:get_power(enums.power_type.MANA)
                if ally_mana then
                    local ally_mana_pct = ally:mana_pct()
                    if ally_mana_pct < mana_tide_threshold then
                        low_mana_count = low_mana_count + 1
                    end
                end
            end
        end
        
        if low_mana_count >= min_players then
            if place_totem(spells.mana_tide_totem, player) then
                return true
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 11: Mana Potion
    -- ========================================================================
    
    if menu.use_mana_potions:get_state() then
        if mana_pct <= menu.mana_potion_at:get() then
            if izi.use_best_mana_potion_safe() then
                return true
            end
        end
    end
    
    return false
end

-- ============================================================================
-- LEVELING / SOLO DPS ROTATION
-- ============================================================================

---@param player game_object
---@param menu table
---@return boolean
local function handle_leveling_dps(player, menu)
    if not menu.enable_leveling_mode:get_state() then
        return false
    end
    
    local target = izi.target()
    local ok_target, target_ok = pcall(function()
        return target and target:is_valid_enemy() and target:is_alive()
    end)
    if not ok_target or not target_ok then
        return false
    end
    
    -- Gather context for intelligent decision making
    local ok_ctx, mana_pct, is_moving, is_casting, target_hp_pct, distance, in_combat = pcall(function()
        local casting = player:is_casting() or player:is_channeling()
        return player:mana_pct(), player:is_moving(), casting, target:get_health_percentage(), target:distance(), player:is_in_combat()
    end)
    if not ok_ctx then
        return false
    end
    local min_dps_mana = menu.solo_dps_mana:get()
    
    -- Safety check: don't start DPS if anyone needs healing according to thresholds
    -- This prevents DPS logic from "ninjaing" the GCD if handle_healing skipped a frame (e.g. for mana wait)
    local healing_threshold = menu.healing_wave_hp:get()
    local _, current_lowest_hp = find_lowest_hp_ally(player, 0)
    if current_lowest_hp < healing_threshold then
        return false -- Skip DPS, return to main loop (which will try handle_healing again next tick)
    end
    
    -- ========================================================================
    -- SITUATION 1: Low HP Target -> Finish with Melee (save mana)
    -- ========================================================================
    if menu.finish_with_melee and menu.finish_with_melee:get_state() then
        local finish_threshold = menu.finish_with_melee_hp and menu.finish_with_melee_hp:get() or 15
        if target_hp_pct <= finish_threshold then
            local ok_auto, is_auto_attacking = pcall(function()
                return player:is_auto_attacking()
            end)
            if not ok_auto then
                is_auto_attacking = false
            end
            if not is_auto_attacking then
                pcall(function()
                    auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
                end)
            end
            return true -- Stop casting, melee to finish
        end
    end
    
    -- ========================================================================
    -- SITUATION 2: Low Mana -> Melee only, conserve mana
    -- ========================================================================
    if mana_pct < min_dps_mana then
        local ok_auto, is_auto_attacking = pcall(function()
            return player:is_auto_attacking()
        end)
        if not ok_auto then
            is_auto_attacking = false
        end
        if not is_auto_attacking and distance <= 8 then
            pcall(function()
                auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
            end)
        end
        return false -- Let auto-attacks do the work
    end
    
    -- Skip if already casting
    if is_casting then
        return false
    end
    
    -- ========================================================================
    -- SITUATION 3: Pulling (not in combat, target at range) -> Lightning Bolt
    -- ========================================================================
    if not in_combat and distance > 8 then
        if menu.use_lightning_bolt and menu.use_lightning_bolt:get_state() then
            if not is_moving and has_enough_mana(player, 20) then
                if spells.lightning_bolt:is_learned() and spells.lightning_bolt:is_castable() and spells.lightning_bolt:cast(target) then
                    return true
                end
            end
        end
    end
    
    -- ========================================================================
    -- SITUATION 4: Moving -> Earth Shock (instant cast)
    -- ========================================================================
    if is_moving then
        if menu.use_earth_shock and menu.use_earth_shock:get_state() then
            if has_enough_mana(player, 10) then
                if spells.earth_shock:is_learned() and spells.earth_shock:is_castable() and spells.earth_shock:cast(target) then
                    return true
                end
            end
        end
        return false -- Can't cast Lightning Bolt while moving
    end
    
    -- ========================================================================
    -- SITUATION 5: Enhancement / Elemental Special (Stormstrike / Totems)
    -- ========================================================================
    if in_combat and distance <= 5 then
        -- Stormstrike (Enhancement)
        if spells.stormstrike:is_learned() and spells.stormstrike:cooldown_up() and has_enough_mana(player, 15) then
            if spells.stormstrike:is_castable() and spells.stormstrike:cast(target) then
                return true
            end
        end
    end

    if in_combat and not is_moving then
         -- Totem of Wrath (Elemental TBC)
         if menu.use_totem_of_wrath and menu.use_totem_of_wrath:get_state() then
              local now = core.game_time()
              if (now - last_totem_cast) >= 10000 and spells.totem_of_wrath:is_learned() then 
                   -- Just drop it if we have mana and it's not spamming too hard
                   if has_enough_mana(player, 15) and place_totem(spells.totem_of_wrath, player) then return true end
              end
         end
    end

    -- ========================================================================
    -- SITUATION 5: High HP Target -> Apply Flame Shock DoT (if missing)
    -- ========================================================================
    if target_hp_pct > 40 then
        if menu.use_flame_shock and menu.use_flame_shock:get_state() then
            if has_enough_mana(player, 15) then
                local debuff_data = buff_manager:get_debuff_data(target, spells.FLAME_SHOCK_DEBUFF_IDS)
                if not debuff_data.is_active then
                    if spells.flame_shock:is_learned() and spells.flame_shock:is_castable() and spells.flame_shock:cast(target) then
                        return true
                    end
                end
            end
        end
    end
    
    -- ========================================================================
    -- SITUATION 6: In Combat, Stationary -> Place Searing Totem (every 60s)
    -- ========================================================================
    if in_combat and not is_moving then
        if menu.use_searing_totem and menu.use_searing_totem:get_state() then
            local now = core.game_time()
            if (now - last_totem_cast) >= 60000 and has_enough_mana(player, 10) then
                if place_totem(spells.searing_totem, player) then
                    return true
                end
            end
        end
    end
    
    -- ========================================================================
    -- SITUATION 7: Chain Lightning (AoE)
    -- ========================================================================
    if menu.use_chain_lightning and menu.use_chain_lightning:get_state() then
        if has_enough_mana(player, 25) and spells.chain_lightning:is_learned() and spells.chain_lightning:cooldown_up() then
            -- Count enemies in range
            local target_pos = target:get_position()
            local enemies = target_pos and performance:get_enemy_list_around(unit_helper, target_pos, 10) or {}
            if #enemies >= 2 then
                if spells.chain_lightning:is_castable() and spells.chain_lightning:cast(target) then
                    return true
                end
            end
        end
    end

    -- ========================================================================
    -- SITUATION 8: Default Filler -> Lightning Bolt
    -- ========================================================================
    if menu.use_lightning_bolt and menu.use_lightning_bolt:get_state() then
        if has_enough_mana(player, 20) then
            if spells.lightning_bolt:is_learned() and spells.lightning_bolt:is_castable() and spells.lightning_bolt:cast(target) then
                return true
            end
        end
    end
    
    -- ========================================================================
    -- FALLBACK: Start auto-attack if in melee range
    -- ========================================================================
    local ok_auto, is_auto_attacking = pcall(function()
        return player:is_auto_attacking()
    end)
    if not ok_auto then
        is_auto_attacking = false
    end
    if distance <= 8 and not is_auto_attacking then
        pcall(function()
            auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
        end)
    end
    
    return false
end

-- ============================================================================
-- MAIN EXECUTION FUNCTION
-- ============================================================================

---@param player game_object
---@param menu table
---@param tick_tracker table|nil
---@param healing_only_mode boolean Whether healing-only mode is active (from toggle or checkbox)
---@return boolean
function rotation_logic:execute(player, menu, tick_tracker, healing_only_mode)
    if not player then
        return false
    end
    
    local ok_alive, alive = pcall(function()
        return player:is_alive()
    end)
    if not ok_alive or not alive then
        return false
    end
    
    -- Store tick tracker reference
    active_tick_tracker = tick_tracker

    -- Detect Spec
    local spec = detect_spec()
    
    -- 1. HEALING & MAINTENANCE (Always Priority for Restoration, or low HP for others)
    local ok_hp, hp_pct = pcall(function()
        return player:get_health_percentage()
    end)
    if not ok_hp then
        return false
    end
    
    if spec == "Restoration" or hp_pct < 60 or healing_only_mode then
        if handle_healing(player, menu) then
            return true
        end
    end

    -- 2. DPS / LEVELING LOGIC (Only if not Healing Only)
    -- healing_only_mode is passed from main.lua - it checks both checkbox and keybind toggle
    if not healing_only_mode and menu.enable_leveling_mode:get_state() then
        -- Handle target engagement/auto-attack
        local target = izi.target()
        local ok_target, target_ok = pcall(function()
            return target and target:is_valid_enemy() and target:is_alive()
        end)
        
        if ok_target and target_ok then
            -- Engagement Logic
            local ok_guid, current_guid = pcall(function()
                return target:get_guid()
            end)
            if not ok_guid then
                last_target_guid = nil
                return false
            end
            
            if menu.auto_attack_target:get_state() then
                local ok_auto, is_auto_attacking = pcall(function()
                    return player:is_auto_attacking()
                end)
                if not ok_auto then
                    is_auto_attacking = false
                end
                
                if current_guid ~= last_target_guid or not is_auto_attacking then
                    local ok_attack = pcall(function()
                        return auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
                    end)
                    if ok_attack then
                        last_target_guid = current_guid
                    else
                        last_target_guid = nil
                        return false
                    end
                end
            end
            
            -- Call DPS Rotation
            if handle_leveling_dps(player, menu) then
                return true
            end
        else
            last_target_guid = nil
        end
    end
    
    -- 3. OUT OF COMBAT MAINTENANCE
    local ok_combat, in_combat = pcall(function()
        return player:is_in_combat()
    end)
    if not ok_combat then
        return false
    end
    
    if not in_combat then
        if handle_out_of_combat(player, menu) then
            return true
        end
    end
    
    return false
end

-- Export utility functions for external use
rotation_logic.is_5sr_active = is_5sr_active
rotation_logic.get_5sr_remaining_ms = get_5sr_remaining_ms
rotation_logic.get_ms_to_mana_tick = get_ms_to_mana_tick
rotation_logic.get_current_spec = function() return current_spec end

return rotation_logic
