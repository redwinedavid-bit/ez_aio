local __object_safety=require("shared/object_safety")
-- ============================================================================
local performance = require("shared/rotation_performance")
-- Priest Healing Rotation AIO (Classic ERA)
-- Action Priority List for Holy/Discipline Healer
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

-- Import spells
local spells = require("rotations/priest/era/spells")

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

-- Wand auto-attack state
local wand_auto_active = false
local last_wand_toggle_ms = 0
local WAND_TOGGLE_THROTTLE_MS = 500
local already_wanding = false

-- Vampiric Touch debounce (prevent double cast)
local last_vt_cast = 0

-- Inventory slot for ranged weapon (wand)
local RANGED_WEAPON_SLOT_ID = 18

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

---Select the optimal Greater Heal rank based on target health deficit and TBC penalty rules
---@param player game_object
---@param target game_object
---@param menu table
---@return any The spell object to cast
local function get_smart_greater_heal(player, target, menu)
    -- If smart downranking is disabled, just return the highest rank wrapper
    if not menu.enable_smart_downranking:get_state() then
        return spells.greater_heal
    end

    local missing_hp = target:get_max_health() - target:get_health()
    local player_level = player:get_level()
    local avoid_penalty = menu.downrank_penalty_prevention:get_state()

    -- Rank objects initialized in spells.lua
    local rank_objects = {
        [1] = spells.gh_r1,
        [2] = spells.gh_r2,
        [3] = spells.gh_r3,
        [4] = spells.gh_r4,
        [5] = spells.gh_r5,
        [7] = spells.gh_r7,
    }

    -- We iterate from lowest rank to highest to find the first rank that heals "enough"
    -- This maximizes mana efficiency.
    local best_fallback = spells.greater_heal
    
    -- Iterate in reverse (lowest level rank first)
    for i = #spells.GH_RANKS, 1, -1 do
        local rank_data = spells.GH_RANKS[i]
        local spell_object = rank_objects[rank_data.rank]
        
        if spell_object and spell_object:is_learned() then
            -- TBC Penalty check: Spells learned 10+ levels below player level
            local has_penalty = rank_data.level < (player_level - 10)
            
            if not (avoid_penalty and has_penalty) then
                -- Does this rank heal enough? 
                -- We use rank_data.heal as an estimate.
                -- If it heals at least 90% of missing HP, it's efficient.
                if rank_data.heal >= (missing_hp * 0.9) then
                    return spell_object
                end
                
                -- Capture the highest learned non-penalized rank in case we need a fallback
                best_fallback = spell_object
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
    -- If smart downranking is disabled, just return the highest rank wrapper
    if not menu.enable_smart_downranking:get_state() then
        return spells.heal
    end

    local missing_hp = target:get_max_health() - target:get_health()
    local player_level = player:get_level()
    local avoid_penalty = menu.downrank_penalty_prevention:get_state()

    -- Rank objects initialized in spells.lua
    local rank_objects = {
        [4] = spells.h_r4,
        [3] = spells.h_r3,
        [2] = spells.h_r2,
        [1] = spells.h_r1,
    }

    local best_fallback = spells.heal
    
    -- Iterate in reverse (lowest level rank first)
    for i = #spells.HEAL_RANKS, 1, -1 do
        local rank_data = spells.HEAL_RANKS[i]
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

    return best_fallback
end

---Select the optimal Lesser Heal rank based on target health deficit
---@param player game_object
---@param target game_object
---@param menu table
---@return any The spell object to cast
local function get_smart_lesser_heal(player, target, menu)
    local deficit = target:get_max_health() - target:get_health()
    
    if spells.lh_r3:is_learned() and deficit >= spells.LH_RANKS[1].heal * 0.9 then
        return spells.lh_r3
    elseif spells.lh_r2:is_learned() and deficit >= spells.LH_RANKS[2].heal * 0.9 then
        return spells.lh_r2
    elseif spells.lh_r1:is_learned() then
        return spells.lh_r1
    end
    
    return spells.lesser_heal
end

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

---Check if player has enough mana
---@param player game_object
---@param min_mana_pct number
---@return boolean
local function has_enough_mana(player, min_mana_pct)
    return player:mana_pct() >= min_mana_pct
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
        local best_rank = spells:get_best_rank(spell_name, deficit)
        
        if best_rank then
            local spell_obj = izi.spell(best_rank.id)
            if spell_obj and spell_obj:is_learned() and spell_obj:cooldown_up() then
                if spell_obj:cast_safe(target) then
                    -- Check if it is actually downranking or just using max rank
                    local max_rank_id = spells[spell_name] and spells[spell_name]:id()
                    local is_max_rank = max_rank_id and (best_rank.id == max_rank_id)
                    
                    if is_max_rank then
                        core.log(string.format("Smart Cast: %s [%s] (ID: %d, ~%d heal) on %s (Deficit: %d) - Max Rank Needed", 
                            spell_name, best_rank.rank_name or "Max", best_rank.id, best_rank.heal_avg, target:get_name(), deficit))
                    else
                        core.log(string.format("Downranking: %s [%s] (ID: %d, ~%d heal) on %s (Deficit: %d)", 
                            spell_name, best_rank.rank_name or "?", best_rank.id, best_rank.heal_avg, target:get_name(), deficit))
                    end
                    return true
                end
            end
        end
    end
    
    -- 2. Fallback: Use highest rank (via spells object)
    local main_spell = spells[spell_name]
    if main_spell and main_spell:is_learned() and main_spell:cooldown_up() then
        if main_spell:cast_safe(target) then
            core.log(string.format("Casting: %s (Max Rank) on %s", spell_name, target:get_name()))
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
        if debuff and debuff.type == enums.buff_type.MAGIC then
            return true
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
        return performance:get_unit_list(player, "get_party_members_in_range", 40, true)
    end)
    if ok_range and party_range and #party_range > 0 then
        return party_range
    end

    -- 2) Fallback: normale Party-Mitglieder
    local ok_party, party = pcall(function()
        return performance:get_unit_list(player, "get_party_members")
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
        GroupState.members = get_group_members(player)
        GroupState.last_member_refresh = now
    end

    GroupState.lowest_ally = player
    GroupState.lowest_hp = player:get_health_percentage() or 100
    GroupState.tank = player
    GroupState.tank_hp = GroupState.lowest_hp
    GroupState.below_aoe_count = 0
    
    local aoe_hp = menu.aoe_hp_threshold:get()
    
    local best_tank_priority = 100 -- Warrior=1, Druid=2
    
    for _, ally in __object_safety.live_ipairs(GroupState.members) do
        if ally and ally:is_alive() then
            local hp = ally:get_health_percentage() or 100
            
            -- Lowest HP detection
            if hp < GroupState.lowest_hp then
                GroupState.lowest_hp = hp
                GroupState.lowest_ally = ally
            end
            
            -- Tank Detection
            local class = ally:get_class()
            local priority = 100
            if class == enums.class_id.WARRIOR then priority = 1
            elseif class == enums.class_id.DRUID then priority = 2
            end
            
            if priority < best_tank_priority then
                best_tank_priority = priority
                GroupState.tank = ally
                GroupState.tank_hp = hp
            end
            
            -- AoE Counts
            if hp < aoe_hp then GroupState.below_aoe_count = GroupState.below_aoe_count + 1 end
        end
    end

    -- Throttled Dispel Detection (Expensive API calls)
    local now = core.game_time()
    if (now - GroupState.last_dispel_refresh) >= DISPEL_CHECK_INTERVAL_MS then
        GroupState.last_dispel_refresh = now
        GroupState.dispel_magic = {}
        GroupState.dispel_disease = {}

        for _, ally in __object_safety.live_ipairs(GroupState.members) do
            if ally and ally:is_alive() and ally.get_debuffs then
                local ok, debuffs = pcall(function() return ally:get_debuffs() end)
                if ok and type(debuffs) == "table" then
                    local has_magic = false
                    local has_disease = false
                    for _, debuff in ipairs(debuffs) do
                        if debuff and debuff.type == enums.buff_type.MAGIC then has_magic = true end
                        if debuff and debuff.type == enums.buff_type.DISEASE then has_disease = true end
                        if has_magic and has_disease then break end
                    end
                    if has_magic then table.insert(GroupState.dispel_magic, ally) end
                    if has_disease then table.insert(GroupState.dispel_disease, ally) end
                end
            end
        end
    end
end


---Find the lowest HP ally
---@param player game_object
---@param min_hp_pct number (optional) minimum HP% to consider (default: 0)
---@return game_object|nil, number
local function find_lowest_hp_ally(player, min_hp_pct)
    return GroupState.lowest_ally, GroupState.lowest_hp
end

---Find tank (first warrior/paladin/druid in group, or main assist)
---@param player game_object
---@return game_object|nil
local function find_tank(player)
    return GroupState.tank
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

---Find best DPS target for Power Infusion
---@param player game_object
---@return game_object|nil
local function find_power_infusion_target(player)
    local group = GroupState.members
    
    -- Priority: Mage > Warlock > other casters > self
    local mages = {}
    local warlocks = {}
    local others = {}
    
    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() and (not __object_safety.same(ally,player)) then
            local class = ally:get_class()
            local mana = ally:get_power(enums.power_type.MANA)
            
            -- Only consider mana users with > 30% mana
            if mana and ally:mana_pct() > 30 then
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
    
    -- Self as fallback
    return player
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
    if player:buff_up(spells.SHADOWFORM_BUFF_ID) then
        return false
    end
    
    -- Check if mounting or casting
    if player:is_mounted() or player:is_casting() or player:is_channeling() then
        return false
    end
    
    -- Cast it
    if spells.shadow_form:cast_safe(player) then
        return true
    end
    
    return false
end

-- ============================================================================
-- OUT-OF-COMBAT LOGIC (BUFFS)
-- ============================================================================

---@param player game_object
---@param menu table
---@return boolean
local function handle_out_of_combat(player, menu)
    local now = core.game_time()
    
    -- Skip if already casting or channeling (Return true to indicate busy)
    if player:is_channeling_or_casting() then
        return true
    end
    
    -- Maintain Shadowform (High priority out of combat)
    if ensure_shadowform(player, menu) then
        return true
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
    
    -- Check if buffs are enabled
    if not menu.use_buffs:get_state() then
        return false
    end
    
    -- Inner Fire (self buff)
    if buff_missing(player, spells.INNER_FIRE_BUFF_IDS) then
        if spells.inner_fire:is_learned() then
            if spells.inner_fire:cast_safe(player) then
                return true
            end
        end
    end
    
    -- Get group members for buffing
    local group = get_group_members(player)
    
    -- Power Word: Fortitude (or Prayer of Fortitude for raids)
    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() then
            if buff_missing(ally, spells.FORTITUDE_BUFF_IDS) then
                -- Try Prayer of Fortitude first for groups
                if #group > 3 and spells.prayer_of_fortitude:is_learned() then
                    if has_enough_mana(player, 40) then
                        if spells.prayer_of_fortitude:cast_safe(ally) then
                            return true
                        end
                    end
                end
                -- Fall back to single target
                if spells.power_word_fortitude:is_learned() then
                    if spells.power_word_fortitude:cast_safe(ally) then
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
                    -- Try Prayer of Spirit first for groups
                    if #group > 3 and spells.prayer_of_spirit:is_learned() then
                        if has_enough_mana(player, 40) then
                            if spells.prayer_of_spirit:cast_safe(ally) then
                                return true
                            end
                        end
                    end
                    -- Fall back to single target
                    if spells.divine_spirit:is_learned() then
                        if spells.divine_spirit:cast_safe(ally) then
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
            if ally and ally:is_alive() then
                if buff_missing(ally, spells.SHADOW_PROTECTION_BUFF_IDS) then
                    if spells.shadow_protection:is_learned() then
                        if spells.shadow_protection:cast_safe(ally) then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    return false
end

-- ============================================================================
-- MANA TICK / 5SR OPTIMIZATION (must be before handle_in_combat)
-- ============================================================================

-- Reference to the tick tracker (passed from main.lua)
local active_tick_tracker = nil

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
    
    -- Skip if casting (Return true to indicate busy)
    if player:is_casting() then
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
    
    -- ========================================================================
    -- PRIORITY 1: Self Emergency (Desperate Prayer)
    -- ========================================================================
    
    if menu.use_desperate_prayer:get_state() and player:is_in_combat() then
        if hp_pct <= menu.desperate_prayer_hp:get() then
            if spells.desperate_prayer:is_learned() then
                if spells.desperate_prayer:cast_safe(player) then
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
        if hp_pct <= menu.hp_potion_at:get() then
            if izi.use_best_health_potion_safe() then
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
                        if spells.fade:cast_safe(player) then
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
    
    -- ========================================================================
    -- PRIORITY 4: Tank Emergency Healing
    -- ========================================================================
    
    local tank = GroupState.tank
    local tank_hp = GroupState.tank_hp
    
    if support_healing_enabled and tank and tank:is_alive() and tank_hp <= tank_emergency_hp then
        -- Inner Focus for mana efficiency on big heals
        if menu.use_inner_focus:get_state() and not is_moving then
            if spells.inner_focus:is_learned() then
                if (now - last_inner_focus_use) > INNER_FOCUS_THROTTLE_MS then
                    if spells.inner_focus:cast_safe(player) then
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
                if spells.power_word_shield:cast_safe(tank) then
                    return true
                end
            end
        end
        
        -- Flash Heal (fast, expensive)
        if not is_moving and has_enough_mana(player, 15) then
            if cast_smart("flash_heal", tank, menu) then
                return true
            end
        end
        
        -- Greater Heal (slow but efficient at low HP)
        if not is_moving and has_enough_mana(player, 20) then
            local gh_spell = get_smart_greater_heal(player, tank, menu)
            if gh_spell and gh_spell:is_learned() then
                if gh_spell:cast_safe(tank) then
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
        -- Power Word: Shield (Smart check)
        local is_rage = is_rage_class(lowest_ally)
        local use_shield_enabled = menu.use_shield:get_state()
        local should_shield = use_shield_enabled and (not is_rage or (not menu.avoid_shield_on_rage_tanks:get_state()) or (lowest_hp <= 15))
        
        if should_shield and not has_weakened_soul(lowest_ally) then
            if spells.power_word_shield:is_learned() then
                if spells.power_word_shield:cast_safe(lowest_ally) then
                    return true
                end
            end
        end
        
        -- Flash Heal
        if not is_moving and has_enough_mana(player, 15) then
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
            -- CoH logic not fully used in Era but keeping structure
            local coh_hp = menu.coh_hp_threshold:get()
            local coh_count = count_allies_below_hp(player, coh_hp)
            
            if coh_count >= menu.coh_min_targets:get() then
                -- Find best target for CoH (usually just cast on local player or a low member)
                if cast_smart("circle_of_healing", lowest_ally or player, menu) then
                    return true
                end
            end
        end

        -- 6.2 Prayer of Healing (Classic AoE - Slow but powerful)
        if not is_moving then
            local low_count = GroupState.below_aoe_count
            
            if low_count >= aoe_threshold then
                if spells.prayer_of_healing:is_learned() then
                    if has_enough_mana(player, 35) then
                        if spells.prayer_of_healing:cast_safe(player) then
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
    
    if support_healing_enabled and lowest_ally and lowest_hp <= flash_heal_hp then
        if not is_moving and has_enough_mana(player, 15) then
            if cast_smart("flash_heal", lowest_ally, menu) then
                return true
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 8: Dispel / Cure Disease
    -- ========================================================================
    
    if support_healing_enabled and menu.use_dispel:get_state() then
        if (now - last_dispel_check) >= DISPEL_CHECK_INTERVAL_MS then
            last_dispel_check = now
            
            -- Magic Dispel
            if menu.use_dispel_magic:get_state() then
                for _, ally in __object_safety.live_ipairs(GroupState.dispel_magic) do
                    if ally and ally:is_alive() then
                        if spells.dispel_magic:is_learned() then
                            if spells.dispel_magic:cast_safe(ally) then
                                return true
                            end
                        end
                    end
                end
            end
            
            -- Disease Cure
            for _, ally in __object_safety.live_ipairs(GroupState.dispel_disease) do
                if ally and ally:is_alive() then
                    -- Prefer Abolish Disease (HoT effect)
                    if spells.abolish_disease:is_learned() then
                        if spells.abolish_disease:cast_safe(ally) then
                            return true
                        end
                    elseif spells.cure_disease:is_learned() then
                        if spells.cure_disease:cast_safe(ally) then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 9: Greater Heal / Heal (Efficient Healing with 5SR Optimization)
    -- ========================================================================
    
    if support_healing_enabled and lowest_ally and lowest_hp <= heal_hp then
        if not is_moving then
            -- 5SR Optimization: Wait if 5SR is about to end for non-emergency heals
            local is_urgent = lowest_hp <= 50
            if not is_urgent and should_delay_for_5sr(player, false) then
                -- Skip casting, wait for 5SR to end
                return false
            end
            
            -- Mana tick optimization: wait for tick if close and low mana
            if not is_urgent and should_wait_for_mana_tick(player, 400) then
                -- Skip casting, wait for mana tick
                return false
            end
            
            -- Greater Heal for lower HP targets
            if lowest_hp <= 60 and has_enough_mana(player, 20) then
                local gh_spell = get_smart_greater_heal(player, lowest_ally, menu)
                if gh_spell and gh_spell:is_learned() then
                    if gh_spell:cast_safe(lowest_ally) then
                        return true
                    end
                end
            end
            
            -- Regular Heal for higher HP
            if has_enough_mana(player, 15) then
                local h_spell = get_smart_heal(player, lowest_ally, menu)
                if h_spell and h_spell:is_learned() then
                    if h_spell:cast_safe(lowest_ally) then
                        return true
                    end
                end
            end
        end
    end
    
    -- ========================================================================
    -- PRIORITY 10: Renew (Preventive HoT with 5SR Optimization)
    -- ========================================================================
    
    if support_healing_enabled and menu.use_renew:get_state() then
        -- Renew is low priority - optimize for mana
        -- Wait for 5SR to end if close
        if should_delay_for_5sr(player, false) then
            return false
        end
        
        -- Wait for mana tick if close
        if should_wait_for_mana_tick(player, 200) then
            return false
        end
        
        local group = GroupState.members
        
        for _, ally in __object_safety.live_ipairs(group) do
            if ally and ally:is_alive() then
                local ally_hp = ally:get_health_percentage() or 100
                
                if ally_hp <= renew_hp then
                    -- Check if Renew is not already active
                    if buff_missing(ally, spells.RENEW_BUFF_IDS) then
                        if has_enough_mana(player, 10) then
                            if cast_smart("renew", ally, menu) then
                                return true
                            end
                        end
                    end
                end
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
                
                if not skip_rage and not has_weakened_soul(tank) then
                    if spells.power_word_shield:is_learned() then
                        if has_enough_mana(player, 15) then
                            if spells.power_word_shield:cast_safe(tank) then
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
    
    if menu.use_power_infusion:get_state() then
        if spells.power_infusion:is_learned() then
            -- Use on DPS caster in group, or self if solo
            local pi_target = find_power_infusion_target(player)
            if pi_target then
                if spells.power_infusion:cast_safe(pi_target) then
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
        if mana_pct <= menu.mana_potion_at:get() then
            if izi.use_best_mana_potion_safe() then
                return true
            end
        end
    end

    -- PRIORITY 14: Lesser Heal Fallback (Very Low Mana)
    if menu.use_lesser_heal_fallback and menu.use_lesser_heal_fallback:get_state() then
        if mana_pct < 10 and lowest_ally and lowest_hp <= heal_hp then
            local lh_spell = get_smart_lesser_heal(player, lowest_ally, menu)
            if lh_spell and lh_spell:is_learned() then
                if lh_spell:cast_safe(lowest_ally) then
                    return true
                end
            end
        end
    end
    
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

    -- Skip if already casting (unless it's a channel we want to break)
    if player:is_casting() then
        return false
    end

    local targets = {}
    if target_override and target_override:is_valid() and target_override:is_alive() then
        targets = { target_override }
    else
        targets = izi.get_ts_targets()
    end
    
    if not targets or #targets == 0 then
        return false
    end

    local now_ms = core.game_time()
    local hp_pct = player:get_health_percentage()
    local mana_pct = player:mana_pct()
    local is_moving = player:is_moving()
    
    -- Pick primary target
    local target = targets[1]
    if not target or not target:is_valid() or not target:is_alive() then
        return false
    end
    
    -- Basic Validity Checks
    if target:is_damage_immune(target.DMG.MAGICAL) or target:is_cc_weak() then
        return false
    end

    -- ========================================================================
    -- SELF PROTECTION (PW:S)
    -- ========================================================================
    if menu.use_shield:get_state() then
        if hp_pct < 95 and not has_weakened_soul(player) and not player:buff_up(spells.POWER_WORD_SHIELD_BUFF_ID) then
            if spells.power_word_shield:is_learned() then
                if spells.power_word_shield:cast_safe(player) then return true end
            end
        end
    end

    -- ========================================================================
    -- CHANNELING & WAND STATE DETECTION
    -- ========================================================================
    local channel_id = 0
    pcall(function() channel_id = player:get_active_channel_spell_id() end)
    
    local is_wanding = (channel_id == 5019)
    if not is_wanding then
        is_wanding = auto_attack_helper:is_auto_attacking(player, auto_attack_helper.ATTACK_TYPE.WAND)
    end
    
    -- Don't interrupt Mind Flay or Starshards
    local is_channeling_dps = false
    local dps_channels = {15407, 18807, 17314, 17313, 17312, 17311, 19305, 19302, 19299, 19296, 16568, 10797, 10796, 10002}
    for _, id in ipairs(dps_channels) do
        if channel_id == id then
            is_channeling_dps = true
            break
        end
    end

    if is_channeling_dps then
        return true
    end

    -- ========================================================================
    -- SHADOWFORM MAINTENANCE
    -- ========================================================================
    local has_shadowform = player:buff_up(spells.SHADOWFORM_BUFF_ID)
    if menu.maintain_shadowform:get_state() and not has_shadowform and not is_moving then
        if spells.shadow_form:is_learned() then
            if spells.shadow_form:cast_safe(player) then return true end
        end
    end

    -- ========================================================================
    -- WAND THRESHOLD LOGIC
    -- ========================================================================
    local target_hp = target:get_health_percentage() or 100
    local wand_hp_threshold = (menu.wand_target_hp and menu.wand_target_hp:get()) or 25
    local low_mana_threshold = (menu.solo_dps_mana and menu.solo_dps_mana:get()) or 30
    
    local finishing_mob = target_hp <= wand_hp_threshold
    local low_mana = mana_pct <= low_mana_threshold
    local wand_mode_enabled = menu.use_wand and menu.use_wand:get_state()
    local has_wand = has_ranged_weapon_equipped(player)

    -- If we are in "Wanding Phase" (Low mana or Low HP), prioritize wanding
    if wand_mode_enabled and has_wand and (finishing_mob or low_mana) then
        if not is_moving then
            if not is_wanding and (now_ms - last_wand_toggle_ms) >= WAND_TOGGLE_THROTTLE_MS then
                last_wand_toggle_ms = now_ms
                if auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.WAND) then
                    return true
                end
            end
            if is_wanding then return true end
        end
    end

    -- ========================================================================
    -- MAIN DPS ROTATION
    -- ========================================================================
    
    -- 1. Shadow Word: Pain (Main Target)
    if target_hp > 15 then
        if spells.shadow_word_pain:is_learned() and not target:debuff_up(spells.shadow_word_pain:id()) then
            if spells.shadow_word_pain:cast_safe(target) then return true end
        end
    end

    -- 2. Vampiric Embrace / Touch
    if menu.use_vampiric_embrace:get_state() and spells.vampiric_embrace:is_learned() then
        if not target:debuff_up(spells.vampiric_embrace:id()) then
            if spells.vampiric_embrace:cast_safe(target) then return true end
        end
    end

    -- 3. Mind Blast (Burst)
    if not is_moving and menu.use_mind_blast:get_state() and spells.mind_blast:is_learned() then
        if spells.mind_blast:cooldown_up() then
            if spells.mind_blast:cast_safe(target) then return true end
        end
    end

    -- 4. Mind Flay / Starshards (Filler)
    if not is_moving then
        if has_shadowform and spells.mind_flay:is_learned() then
            if spells.mind_flay:cast_safe(target) then return true end
        elseif not has_shadowform then
            -- Pre-Shadowform / Night Elf Racials
            if spells.starshards:is_learned() then
                if spells.starshards:cast_safe(target) then return true end
            end
            if spells.holy_fire:is_learned() and target_hp > 30 then
                if spells.holy_fire:cast_safe(target) then return true end
            end
            if spells.smite:is_learned() then
                if spells.smite:cast_safe(target) then return true end
            end
        end
    end

    -- Final Fallback: Wand if everything else is on cooldown or we can't cast
    if wand_mode_enabled and has_wand and not is_moving and not is_wanding then
        if (now_ms - last_wand_toggle_ms) >= WAND_TOGGLE_THROTTLE_MS then
            last_wand_toggle_ms = now_ms
            auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.WAND)
        end
    end

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
        if enemy and enemy:is_valid() and enemy:is_alive() then
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
        if spells.psychic_scream:cast_safe(player) then
            core.log("Panic Fear! (HP: " .. math.floor(hp_pct) .. "% <= " .. hp_threshold .. "%)")
            return true
        end
    end

    -- AoE CC Condition: ONLY if there are MANY enemies (mob_threshold+ enemies)
    -- This should be a high threshold like 3+ to avoid triggering on normal pulls
    if mob_threshold >= 3 and enemies_in_8yd >= mob_threshold then
        if spells.psychic_scream:cast_safe(player) then
            core.log("AoE Fear! (" .. enemies_in_8yd .. " enemies >= " .. mob_threshold .. ")")
            return true
        end
    end

    return false
end

-- ============================================================================
-- MAIN EXECUTE FUNCTION
-- ============================================================================

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

    local mana_pct = player:mana_pct()
    local focus = get_focus_target()
    local target = izi.target()

    -- 1. SW:D CC Breaker (vs Poly/Fear)
    if menu.use_swd_breaker:get_state() and spells.shadow_word_death and spells.shadow_word_death:is_learned() and spells.shadow_word_death:cooldown_up() then
        local enemy_casters = {}
        if focus and focus:is_valid_enemy() then table.insert(enemy_casters, focus) end
        if target and target:is_valid_enemy() then table.insert(enemy_casters, target) end

        for _, enemy in __object_safety.live_ipairs(enemy_casters) do
            if enemy:is_casting_spell() then
                local spell_id = enemy:get_active_spell_id()
                local cc_ids = { 118, 12824, 12825, 12826, 28271, 28272, 5782, 6213, 6215 }
                local is_cc = false
                for _, id in ipairs(cc_ids) do if spell_id == id then is_cc = true break end end

                if is_cc then
                    local cast_pct = enemy:get_cast_pct()
                    if cast_pct > 85 then
                        if cast_spell(spells.shadow_word_death, enemy, player) then
                            return true
                        end
                    end
                end
            end
        end
    end

    -- 2. Offensive Dispel (Purge)
    if menu.use_offensive_dispel:get_state() and spells.dispel_magic:is_learned() then
        local purge_target = target
        if focus and focus:is_valid_enemy() then purge_target = focus end

        if purge_target and purge_target:is_valid_enemy() then
            local high_priority_ids = { 2825, 32182, 29166, 10060, 10278, 1022 }
            local should_purge = false
            
            for _, id in ipairs(high_priority_ids) do
                if purge_target:buff_up(id) then
                    should_purge = true
                    break
                end
            end

            if not should_purge and not menu.purge_high_priority_only:get_state() then
                if purge_target:has_dispellable_magic_buff() then
                    should_purge = true
                end
            end

            if should_purge then
                if cast_spell(spells.dispel_magic, purge_target, player) then
                    return true
                end
            end
        end
    end

    -- 3. Mana Burn (Strategic)
    if menu.use_mana_burn:get_state() and spells.mana_burn:is_learned() and mana_pct > 30 then
        local burn_target = nil
        if focus and focus:is_valid_enemy() and focus:get_max_power(0) > 0 then
            burn_target = focus
        elseif target and target:is_valid_enemy() and target:get_max_power(0) > 0 then
            burn_target = target
        end

        if burn_target and (burn_target:mana_pct() or 0) > menu.mana_burn_target_mana:get() then
            if not player:is_moving() and cast_spell(spells.mana_burn, burn_target, player) then
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
    
    -- Refresh spell data
    if spells and spells.refresh then
        spells:refresh()
    end
    
    -- Check if script is enabled
    if not menu.enable_script_check:get_state() then
        return false
    end

    -- PvP Logic (Highest Priority)
    if handle_pvp_logic(player, menu) then
        return true
    end
    
    -- ========================================================================
    -- DEFENSIVE / UTILITY (Highest Priority)
    -- ========================================================================
    
    -- Global Shadowform Check (even before combat logic)
    -- Only if NOT in healing-only mode (healers usually don't want SF)
    local healing_only_mode = menu.healing_only and menu.healing_only:get_state()
    if not healing_only_mode and ensure_shadowform(player, menu) then
        return true
    end

    if local_player:is_in_combat() then
        if handle_emergency_utility(local_player, menu) then
            return true
        end
    end
    
    -- Out-of-Combat: Buffs and Attack on Target
    if not player:is_in_combat() then
        -- Attack on Target: Start DPS when enemy target is selected (even if not in combat)
        -- SKIP if Healing Only mode is enabled
        local healing_only_mode = menu.healing_only and menu.healing_only:get_state()
        if not healing_only_mode and menu.attack_on_target and menu.attack_on_target:get_state() then
            local target = izi.target()
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
    local healing_only_mode = menu.healing_only and menu.healing_only:get_state()
    local has_shadowform = player:buff_up(spells.SHADOWFORM_BUFF_ID)
    
    if healing_only_mode then
        -- HEALING ONLY: Only do healing, no DPS at all
        -- (Safe to run OOC as items are gated by is_in_combat check now)
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
    
    -- SOLO or GROUP HEALTHY: Do DPS first, then check for healing
    -- Only DPS if we are actually in combat (to prevent pulling while OOC unless manually targeted)
    if player:is_in_combat() and (is_solo or all_healthy) then
        if handle_shadow_dps(player, menu) then
            return true
        end
    end
    
    -- GROUP NEEDS HEALING (or fallback from DPS): Heal first
    if handle_in_combat(player, menu) then
        return true
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
