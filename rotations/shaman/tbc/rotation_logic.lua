local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Shaman Rotation Logic (TBC Classic 2.4.3)
-- High-Quality Logic for Restoration, Elemental, and Enhancement
-- Mage-Style Professional Structure + Advanced Totem & Auto-Attack
-- ============================================================================

local rotation_logic = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

---@type rotation_pause
local rotation_pause = require("shared/rotation_pause")

local spells = require("rotations/shaman/tbc/spells")

local healthstone_item = izi.item({ 9421, 19013, 19012, 19011, 19010, 19009, 19008, 19007, 19006, 19005, 19004, 5510, 5509, 5511, 5512 })

-- ============================================================================
-- STATE TRACKING
-- ============================================================================

local weapon_buff_state = {
    mh = { last_cast = 0, item_id = 0 },
    oh = { last_cast = 0, item_id = 0 }
}
local last_diagnostic_ms = 0
local last_es_log_ms = 0
local WEAPON_BUFF_THROTTLE_MS = 25 * 60 * 1000 -- 25 Minutes
local offhand_buff_failures = 0 -- Track failed offhand buff attempts
local MAX_OFFHAND_FAILURES = 3 -- Stop trying after this many failures

-- Totem State Tracking
local last_totem_cast_ms = 0
local TOTEM_CAST_THROTTLE_MS = 2000 -- Increased safety margin for state sync

local active_totems = {
    earth = { pos = nil, start_time = 0, duration = 0, name = "None", last_cast = 0 },
    fire = { pos = nil, start_time = 0, duration = 0, name = "None", last_cast = 0 },
    water = { pos = nil, start_time = 0, duration = 0, name = "None", last_cast = 0 },
    air = { pos = nil, start_time = 0, duration = 0, name = "None", last_cast = 0 }
}

-- Totem Twisting State
local twist_state = {
    last_twist_ms = 0,
    current_totem = "windfury", -- "windfury" or "grace_of_air"
    twist_phase = false -- true = just placed GoA, need to place WF next
}

-- Auto-Attack Tracking
local last_attack_toggle_ms = 0
local ATTACK_TOGGLE_THROTTLE_MS = 350
local current_attack_guid = nil

-- Reference to the tick tracker
local active_tick_tracker = nil
local is_post_combat_healing = false

local function is_elite(unit)
    if not unit then return false end
    local ok, result = pcall(function() return unit:is_elite() end)
    if ok then return result == true end
    
    -- Fallback: check classification if is_elite() fails/missing
    local ok2, classification = pcall(function() return unit:get_classification() end)
    return ok2 and classification and classification >= 1 -- 1=Elite, 2=RareElite, etc.
end

-- ============================================================================
-- UTILITY FUNCTIONS (Mage Pattern)
-- ============================================================================

local function num(v, fallback)
    return tonumber(v) or fallback
end

local function menu_enabled(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get_state then
        return fallback
    end
    return menu[key]:get_state() == true
end

local function menu_number(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get then
        return fallback
    end
    return num(menu[key]:get(), fallback)
end

local function hp_pct(unit)
    if not unit then return 0 end
    return num(unit:get_health_percentage(), 0)
end

local function mana_pct(player)
    if not player then return 0 end
    return num(player:mana_pct(), 0)
end

local function is_moving(player)
    if not player then return false end
    return player:is_moving()
end

local function spell_ready(spell)
    if not spell then return false end
    return spell:is_learned() and spell:cooldown_up()
end

local function has_buff(unit, buff_ids)
    if not unit or not buff_ids then return false end
    local data = buff_manager:get_buff_data(unit, buff_ids)
    return data and data.is_active == true
end

local function buff_missing(unit, buff_ids)
    return not has_buff(unit, buff_ids)
end

local function has_debuff(unit, debuff_ids)
    if not unit or not debuff_ids then return false end
    local data = buff_manager:get_debuff_data(unit, debuff_ids)
    return data and data.is_active == true
end

local function debuff_missing(unit, debuff_ids)
    return not has_debuff(unit, debuff_ids)
end

-- Totem Slots for get_totem_info API
-- Standard WoW API Slots: Fire=1, Earth=2, Water=3, Air=4
local TOTEM_SLOTS = { fire = 1, earth = 2, water = 3, air = 4 }

core.log("[Shaman AIO] Logic Version 3.0 Loaded (Internal State Totem Tracking)")

local function get_active_totem(player, element)
    local slot = TOTEM_SLOTS[element]
    if not slot then return nil end
    
    local has_totem, name, start_time, duration, spell_id = player:get_totem_info(slot)
    
    if has_totem then
        return { name = name, spell_id = spell_id, start_time = start_time, duration = duration }
    end
    return nil
end

local function is_totem_match(actual, wanted_ids, wanted_name)
    if not actual then return false end
    
    -- 1. Try matching by Spell ID
    if actual.spell_id and wanted_ids then
        for _, id in ipairs(wanted_ids) do
            if actual.spell_id == id then return true end
        end
    end
    
    -- 2. Partial localized name match
    if actual.name and wanted_ids then
        local lower_actual = string.lower(actual.name)
        if lower_actual ~= "" then
            for _, id in ipairs(wanted_ids) do
                local loc = core.spell_book.get_spell_name(id)
                if loc then
                    local lower_loc = string.lower(loc)
                    if string.find(lower_actual, lower_loc, 1, true) then return true end
                end
            end
        end
    end

    -- 3. WORLD SCAN FALLBACK: NPC ID or Name check for Units
    local player = core.object_manager.get_local_player()
    if player and wanted_ids then
        local pos = player:get_position()
        local objs = core.object_manager.get_all_objects()
        for _, obj in __object_safety.live_ipairs(objs) do
            if obj.npc_id and obj:npc_id() > 0 then
                local obj_pos = obj:get_position()
                if obj_pos and obj_pos:dist_to(pos) < 8 then
                    local nid = obj:npc_id()
                    local oname = obj:get_name()
                    for _, id in ipairs(wanted_ids) do
                        -- Exact ID match
                        if nid == id then return true end
                        -- Name match from world unit
                        local loc = core.spell_book.get_spell_name(id)
                        if loc and oname and string.find(string.lower(oname), string.lower(loc), 1, true) then
                            return true
                        end
                    end
                end
            end
        end
    end
    
    return false
end

local function get_distance(pos1, pos2)
    if not pos1 or not pos2 then return 999 end
    local dx = pos1.x - pos2.x
    local dy = pos1.y - pos2.y
    local dz = pos1.z - pos2.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- ============================================================================
-- AUTO-ATTACK MANAGEMENT (Mage-Style)
-- ============================================================================

local function stop_attack_if_casting(player, target)
    if not player or not target then return end
    if player:is_channeling_or_casting() then
        local now = core.game_time()
        if (now - last_attack_toggle_ms) > ATTACK_TOGGLE_THROTTLE_MS then
            if player:is_auto_attacking() then
                auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
                last_attack_toggle_ms = now
            end
        end
    end
end

local function handle_auto_attack(player, target, menu)
    if not target or not target:is_alive() or not target:is_valid_enemy() then return false end
    if not menu_enabled(menu, "auto_melee_engage") then return false end

    local now = core.game_time()
    if (now - last_attack_toggle_ms) < ATTACK_TOGGLE_THROTTLE_MS then return false end

    local dist = target:distance()
    local max_dist = menu_number(menu, "melee_distance", 5)
    
    -- Engagement Logic
    if dist <= max_dist then
        if not player:is_auto_attacking() then
            if auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE) then
                last_attack_toggle_ms = now
                core.log("[Shaman AIO] Auto-Attack Started (Engagement)")
                return true
            end
        end
    else
        -- If too far, stop attack to prevent target switching issues or unintended pulls
        if player:is_auto_attacking() then
            auto_attack_helper:stop_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
            last_attack_toggle_ms = now
            return true
        end
    end

    return false
end

-- ============================================================================
-- TOTEM MANAGEMENT
-- ============================================================================

local function place_totem(element, spell, player, name, buff_ids, duration_sec)
    if not spell:is_castable() then return false end
    
    -- Throttle: Don't cast if we recently cast something in this slot (wait for server sync)
    local now = core.game_time()
    if now < active_totems[element].last_cast + 2500 then return false end
    
    if spell:cast() then
        active_totems[element] = {
            pos = player:get_position(),
            start_time = now,
            duration = (duration_sec or 120) * 1000,
            name = name,
            last_cast = now
        }
        core.log("[Shaman AIO] Totem Placed: " .. name .. " (" .. element .. ")")
        return true
    end
    return false
end

local function handle_totems(player, menu)
    if not menu_enabled(menu, "use_totems") then return false end
    if is_moving(player) then return false end
    
    -- Suggestion: Only place totems in combat to save mana/stealth
    if menu_enabled(menu, "totems_combat_only") and not player:is_in_combat() then return false end
    
    local now = core.game_time()
    local play_pos = player:get_position()
    local auto_recast = menu_enabled(menu, "auto_recast_range")
    local max_dist = menu_number(menu, "totem_range", 20)

    -- 1. Earth Totems
    local earth_idx = menu_number(menu, "earth_totem_selection", 1)
    if earth_idx > 1 then
        local spell, spell_ids, name, buffs, dur = nil, nil, "None", nil, 120
        if earth_idx == 2 then spell, spell_ids, name, buffs = spells.strength_of_earth_totem, spells.strength_of_earth_totem_ids, "SoE", spells.SOE_BUFF_IDS
        elseif earth_idx == 3 then spell, spell_ids, name, buffs = spells.stoneskin_totem, spells.stoneskin_totem_ids, "Stoneskin", spells.STONESKIN_BUFF_IDS
        elseif earth_idx == 4 then spell, spell_ids, name = spells.tremor_totem, spells.tremor_totem_ids, "Tremor"
        elseif earth_idx == 5 then spell, spell_ids, name = spells.earthbind_totem, spells.earthbind_totem_ids, "Earthbind"
        elseif earth_idx == 6 then spell, spell_ids, name = spells.stoneclaw_totem, spells.stoneclaw_totem_ids, "Stoneclaw"
        end
        
        local actual = get_active_totem(player, "earth")
        local state = active_totems.earth
        local needs_recast = false
        local effective_dur_ms = dur * 1000
        
        -- PRIORITY 1: Trust internal state if we recently placed the desired totem
        if state.name == name and state.start_time > 0 then
            local elapsed = now - state.start_time
            if elapsed < effective_dur_ms then
                if auto_recast and state.pos and get_distance(play_pos, state.pos) > max_dist then
                    needs_recast = true
                end
            else
                needs_recast = true -- Expired
            end
        elseif not actual or not is_totem_match(actual, spell_ids, name) then
            needs_recast = true
        else
            if not state.pos then state.pos = play_pos end
            if auto_recast and get_distance(play_pos, state.pos) > max_dist then
                needs_recast = true
            end
        end

        if needs_recast then
            if place_totem("earth", spell, player, name, buffs, dur) then return true end
        end
    end

    -- 2. Fire Totems
    local fire_idx = menu_number(menu, "fire_totem_selection", 1)
    if fire_idx > 1 then
        local spell, spell_ids, name, buffs, dur = nil, nil, "None", nil, 60
        if fire_idx == 2 then spell, spell_ids, name, buffs = spells.totem_of_wrath, spells.totem_of_wrath_ids, "ToW", spells.TOW_BUFF_IDS
        elseif fire_idx == 3 then spell, spell_ids, name = spells.searing_totem, spells.searing_totem_ids, "Searing"
        elseif fire_idx == 4 then spell, spell_ids, name, dur = spells.fire_nova_totem, spells.fire_nova_totem_ids, "FireNova", 5
        elseif fire_idx == 5 then spell, spell_ids, name = spells.magma_totem, spells.magma_totem_ids, "Magma"
        elseif fire_idx == 6 then spell, spell_ids, name = spells.flametongue_totem, spells.flametongue_totem_ids, "Flametongue"
        end

        local actual = get_active_totem(player, "fire")
        local state = active_totems.fire
        local needs_recast = false
        local effective_dur_ms = ((name == "FireNova") and 20 or dur) * 1000
        
        -- PRIORITY 1: Trust internal state if we recently placed the desired totem
        if state.name == name and state.start_time > 0 then
            local elapsed = now - state.start_time
            if elapsed < effective_dur_ms then
                -- Totem still within duration, only check range
                if auto_recast and state.pos then
                    if get_distance(play_pos, state.pos) > max_dist then 
                        needs_recast = true 
                    end
                end
                -- Otherwise don't recast
            else
                -- Totem expired
                needs_recast = true
            end
        -- PRIORITY 2: Check API if we don't have internal state
        elseif not actual then
            needs_recast = true
        -- PRIORITY 3: Check if active totem matches (fallback)
        elseif not is_totem_match(actual, spell_ids, name) then
            -- Different totem is active, check if it's an offensive one we shouldn't override
            local is_offensive_active = false
            if actual.name then
                local low = string.lower(actual.name)
                local offensive_spells = { spells.fire_nova_totem_ids, spells.magma_totem_ids }
                for _, group in ipairs(offensive_spells) do
                    for _, id in ipairs(group) do
                        local loc = core.spell_book.get_spell_name(id)
                        if loc and string.find(low, string.lower(loc), 1, true) then
                            is_offensive_active = true
                            break
                        end
                    end
                    if is_offensive_active then break end
                end
            end
            if not is_offensive_active then
                needs_recast = true
            end
        else
            -- Totem matches, adopt position if needed
            if not state.pos then state.pos = play_pos end
            if auto_recast and get_distance(play_pos, state.pos) > max_dist then
                needs_recast = true
            end
        end

        if needs_recast then
            if place_totem("fire", spell, player, name, buffs, dur) then return true end
        end
    end

    -- 3. Water Totems
    local water_idx = menu_number(menu, "water_totem_selection", 1)
    if water_idx > 1 then
        local spell, spell_ids, name, buffs, dur = nil, nil, "None", nil, 120
        if water_idx == 2 then spell, spell_ids, name, buffs = spells.healing_stream_totem, spells.healing_stream_totem_ids, "HST", spells.HST_BUFF_IDS
        elseif water_idx == 3 then spell, spell_ids, name, buffs = spells.mana_spring_totem, spells.mana_spring_totem_ids, "MST", spells.MST_BUFF_IDS
        elseif water_idx == 4 then spell, spell_ids, name = spells.poison_cleansing_totem, spells.poison_cleansing_totem_ids, "Poison"
        elseif water_idx == 5 then spell, spell_ids, name = spells.disease_cleansing_totem, spells.disease_cleansing_totem_ids, "Disease"
        elseif water_idx == 6 then spell, spell_ids, name = spells.mana_tide_totem, spells.mana_tide_totem_ids, "ManaTide", nil, 12
        end

        local actual = get_active_totem(player, "water")
        local state = active_totems.water
        local needs_recast = false
        local effective_dur_ms = dur * 1000
        
        -- PRIORITY 1: Trust internal state
        if state.name == name and state.start_time > 0 then
            local elapsed = now - state.start_time
            if elapsed < effective_dur_ms then
                if auto_recast and state.pos and get_distance(play_pos, state.pos) > max_dist then
                    needs_recast = true
                end
            else
                needs_recast = true -- Expired
            end
        elseif not actual or not is_totem_match(actual, spell_ids, name) then
            needs_recast = true
        else
            if not state.pos then state.pos = play_pos end
            if auto_recast and get_distance(play_pos, state.pos) > max_dist then
                needs_recast = true
            end
        end

        if needs_recast then
            if place_totem("water", spell, player, name, buffs, dur) then return true end
        end
    end

    -- 4. Air Totems (with Totem Twisting support)
    local air_idx = menu_number(menu, "air_totem_selection", 1)
    local twisting_enabled = menu_enabled(menu, "enable_totem_twisting")
    local twist_interval_ms = menu_number(menu, "twist_interval", 9) * 1000
    
    -- TOTEM TWISTING LOGIC
    if twisting_enabled and spell_ready(spells.windfury_totem) and spell_ready(spells.grace_of_air_totem) then
        local time_since_twist = now - twist_state.last_twist_ms
        
        -- Phase 1: If we just placed GoA (twist_phase = true), immediately place WF
        if twist_state.twist_phase then
            -- Place Windfury Totem immediately after GoA
            if place_totem("air", spells.windfury_totem, player, "Windfury", spells.WF_BUFF_IDS, 120) then
                twist_state.current_totem = "windfury"
                twist_state.twist_phase = false
                core.log("[Shaman AIO] Totem Twist: Windfury placed (twist complete)")
                return true
            end
        -- Phase 2: Time to twist - place GoA briefly
        elseif time_since_twist >= twist_interval_ms then
            -- Check if WF is currently active (we need WF as the base totem)
            local air_state = active_totems.air
            local wf_active = air_state.name == "Windfury" and (now - air_state.start_time) < 120000
            
            if wf_active or twist_state.current_totem == "windfury" then
                -- Place Grace of Air to refresh its buff
                if place_totem("air", spells.grace_of_air_totem, player, "GoA", spells.GOA_BUFF_IDS, 120) then
                    twist_state.current_totem = "grace_of_air"
                    twist_state.twist_phase = true -- Signal to place WF next tick
                    twist_state.last_twist_ms = now
                    core.log("[Shaman AIO] Totem Twist: Grace of Air placed")
                    return true
                end
            else
                -- WF not active, place it first
                if place_totem("air", spells.windfury_totem, player, "Windfury", spells.WF_BUFF_IDS, 120) then
                    twist_state.current_totem = "windfury"
                    twist_state.twist_phase = false
                    twist_state.last_twist_ms = now
                    core.log("[Shaman AIO] Totem Twist: Initial Windfury placed")
                    return true
                end
            end
        -- Phase 3: Between twists, ensure WF is up
        else
            local air_state = active_totems.air
            local needs_wf = air_state.name ~= "Windfury" or (now - air_state.start_time) >= 120000
            
            -- Also check range
            if not needs_wf and auto_recast and air_state.pos then
                if get_distance(play_pos, air_state.pos) > max_dist then
                    needs_wf = true
                end
            end
            
            if needs_wf and not twist_state.twist_phase then
                if place_totem("air", spells.windfury_totem, player, "Windfury", spells.WF_BUFF_IDS, 120) then
                    twist_state.current_totem = "windfury"
                    core.log("[Shaman AIO] Totem Twist: Windfury refreshed")
                    return true
                end
            end
        end
    -- NORMAL AIR TOTEM LOGIC (no twisting)
    elseif air_idx > 1 then
        local spell, spell_ids, name, buffs, dur = nil, nil, "None", nil, 120
        if air_idx == 2 then spell, spell_ids, name, buffs = spells.windfury_totem, spells.windfury_totem_ids, "Windfury", spells.WF_BUFF_IDS
        elseif air_idx == 3 then spell, spell_ids, name, buffs = spells.grace_of_air_totem, spells.grace_of_air_totem_ids, "GoA", spells.GOA_BUFF_IDS
        elseif air_idx == 4 then spell, spell_ids, name, buffs = spells.wrath_of_air_totem, spells.wrath_of_air_totem_ids, "WoA", spells.WOA_BUFF_IDS
        elseif air_idx == 5 then spell, spell_ids, name = spells.grounding_totem, spells.grounding_totem_ids, "Grounding", nil, 45
        elseif air_idx == 6 then spell, spell_ids, name = spells.tranquil_air_totem, spells.tranquil_air_totem_ids, "TranquilAir"
        end

        local actual = get_active_totem(player, "air")
        local state = active_totems.air
        local needs_recast = false
        local effective_dur_ms = dur * 1000
        
        -- PRIORITY 1: Trust internal state
        if state.name == name and state.start_time > 0 then
            local elapsed = now - state.start_time
            if elapsed < effective_dur_ms then
                if auto_recast and state.pos and get_distance(play_pos, state.pos) > max_dist then
                    needs_recast = true
                end
            else
                needs_recast = true -- Expired
            end
        elseif not actual or not is_totem_match(actual, spell_ids, name) then
            needs_recast = true
        else
            if not state.pos then state.pos = play_pos end
            if auto_recast and get_distance(play_pos, state.pos) > max_dist then
                needs_recast = true
            end
        end

        if needs_recast then
            if place_totem("air", spell, player, name, buffs, dur) then return true end
        end
    end

    return false
end

-- ============================================================================
-- GROUP HELPERS
-- ============================================================================

local function get_group_members(player)
    local ok, members = pcall(function()
        return player:get_party_members_in_range(40, true)
    end)
    if ok and members and #members > 0 then return members end
    
    local ok2, members2 = pcall(function()
        return player:get_party_members()
    end)
    if ok2 and members2 and #members2 > 0 then return members2 end
    
    return { player }
end

local function find_lowest_hp_ally(player)
    local group = get_group_members(player)
    local lowest_ally = nil
    local lowest_hp = 101
    
    for _, ally in ipairs(group) do
        if ally and ally:is_alive() then
            local hp = hp_pct(ally)
            if hp < lowest_hp then
                lowest_hp = hp
                lowest_ally = ally
            end
        end
    end
    return lowest_ally, lowest_hp
end

local function get_focus_target(player)
    local ok_fn, fn = pcall(function()
        return player and player.get_focus_target or nil
    end)
    if ok_fn and type(fn) == "function" then
        local ok, target = pcall(function()
            return player:get_focus_target()
        end)
        if ok then return target end
    end

    local ok2, target2 = pcall(function()
        return izi.focus()
    end)
    return ok2 and target2 or nil
end

local function find_tank(player)
    local group = get_group_members(player)
    -- PRIORITY 1: Check for explicit "Focus" if not in Focus mode already (fallback)
    local focus = get_focus_target(player)
    if focus and focus:is_alive() and focus:is_friendly() then
        return focus
    end

    -- PRIORITY 2: Check for Tanks by Class AND Stance/Aura
    local candidates = {}
    for _, ally in ipairs(group) do
        if ally and ally:is_alive() then
            local class = ally:get_class()
            -- Warriors (Defensive Stance: 1)
            if class == 1 and ally:has_aura(71) then table.insert(candidates, { u = ally, p = 10 })
            -- Paladins (Righteous Fury: 25780)
            elseif class == 2 and ally:has_aura(25780) then table.insert(candidates, { u = ally, p = 9 })
            -- Druids (Dire Bear: 9634 / Bear: 768)
            elseif class == 11 and (ally:has_aura(9634) or ally:has_aura(768)) then table.insert(candidates, { u = ally, p = 8 })
            end
        end
    end

    if #candidates > 0 then
        table.sort(candidates, function(a, b) return a.p > b.p end)
        return candidates[1].u
    end

    -- PRIORITY 3: Fallback to Class-only check
    for _, class_id in ipairs({ 1, 2, 11 }) do
        for _, ally in ipairs(group) do
            if ally and ally:is_alive() and ally:get_class() == class_id then
                return ally
            end
        end
    end
    
    return player
end

---Select the Earth Shield target based on menu settings
local function get_earth_shield_target(player, menu)
    local mode = menu_number(menu, "earth_shield_mode", 1)
    
    if mode == 2 then -- Focus
        local focus = get_focus_target(player)
        if focus and focus:is_alive() and focus:is_friendly() then
            return focus
        end
    elseif mode == 3 then -- Main Tank (Raid Assigned)
        -- Fallback to find_tank if no explicit "Main Tank" API available, 
        -- but usually users want the assigned MT.
        return find_tank(player)
    end
    
    -- Default/Auto (Priority)
    return find_tank(player)
end

local function count_injured_allies(player, hp_threshold)
    local group = get_group_members(player)
    local count = 0
    for _, ally in ipairs(group) do
        if ally and ally:is_alive() and hp_pct(ally) <= hp_threshold then
            count = count + 1
        end
    end
    return count
end

-- ============================================================================
-- BUFFS & MAINTENANCE
-- ============================================================================

local function handle_maintenance(player, menu)
    -- 1. Water Shield (Highest Priority for Mana)
    if menu_enabled(menu, "use_water_shield") and spell_ready(spells.water_shield) then
        if buff_missing(player, spells.WATER_SHIELD_IDS) then
            if spells.water_shield:is_castable({ skip_facing = true }) and spells.water_shield:cast(player) then return true end
        end
    end

    -- 2. Earth Shield (Maintain on Target)
    if menu_enabled(menu, "use_earth_shield") and spell_ready(spells.earth_shield) then
        local es_target = get_earth_shield_target(player, menu)
        if es_target and buff_missing(es_target, spells.EARTH_SHIELD_IDS) then
            local castable = spells.earth_shield:is_castable()
            if castable then
                if spells.earth_shield:cast(es_target) then
                    core.log("[Shaman AIO] Earth Shield applied to: " .. (es_target:get_name() or "target"))
                    return true
                else
                    local now = core.game_time()
                    if (now - last_es_log_ms) > 5000 then
                        core.log("[Shaman AIO] Earth Shield cast FAILED on: " .. (es_target:get_name() or "target"))
                        last_es_log_ms = now
                    end
                end
            else
                local now = core.game_time()
                if (now - last_es_log_ms) > 5000 then
                    core.log("[Shaman AIO] Earth Shield not castable (target: " .. (es_target:get_name() or "unknown") .. ")")
                    last_es_log_ms = now
                end
            end
        end
    end

    -- 3. Weapon Buffs - Robust detection with separate MH/OH throttles
    if menu_enabled(menu, "use_weapon_buff") then
        local now = core.game_time()
        
        -- Mainhand Logic
        local mh_slot = player:get_item_at_inventory_slot(16) 
        if mh_slot and mh_slot.object then
            local mh_item = mh_slot.object
            local mh_item_id = mh_item:get_item_id() or 0
            
            -- Reset throttle if weapon swapped
            if mh_item_id ~= weapon_buff_state.mh.item_id then
                core.log("[Shaman AIO] MH Swapped: " .. weapon_buff_state.mh.item_id .. " -> " .. mh_item_id)
                weapon_buff_state.mh.last_cast = 0
                weapon_buff_state.mh.item_id = mh_item_id
            end

            -- Throttle check (Allow initial cast or every 10s for detection, but 30m for cast itself)
            if weapon_buff_state.mh.last_cast == 0 or (now - weapon_buff_state.mh.last_cast) > 10000 then
                local mh_enchant_id = mh_item:item_enchant_id() or 0
                local has_enchant = mh_item:item_has_enchant()
                local enchant_remains = mh_item:item_enchant_expiration() or 0
                
                -- Detection logic: Success if ID > 0 OR (has_enchant is true AND expiration is significant)
                if mh_enchant_id == 0 and not (has_enchant and enchant_remains > 30) then
                    -- Long throttle check (Don't spam if detection is broken)
                    if weapon_buff_state.mh.last_cast == 0 or (now - weapon_buff_state.mh.last_cast) > WEAPON_BUFF_THROTTLE_MS then
                        local mh_buff = menu_number(menu, "weapon_buff_mh", 4)
                        local spell_mh = nil
                        if mh_buff == 1 then spell_mh = spells.rockbiter_weapon
                        elseif mh_buff == 2 then spell_mh = spells.flametongue_weapon
                        elseif mh_buff == 3 then spell_mh = spells.frostbrand_weapon
                        elseif mh_buff == 4 then spell_mh = spells.windfury_weapon
                        end

                        if spell_mh then
                            local can_cast = spell_mh:is_castable({ skip_facing = true })
                            if can_cast then
                                if spell_mh:cast(player) then
                                    weapon_buff_state.mh.last_cast = now
                                    core.log("[Shaman AIO] Applying MH Buff: " .. (mh_buff or "nil"))
                                    return true
                                end
                            else
                                if (now - last_diagnostic_ms) > 10000 then
                                    core.log("[Shaman AIO] MH Buff Not Castable (Buff: " .. tostring(mh_buff) .. ")")
                                    last_diagnostic_ms = now
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Offhand Logic
        local oh_slot = player:get_item_at_inventory_slot(17) 
        if oh_slot and oh_slot.object then
            local oh_item = oh_slot.object
            local oh_item_id = oh_item:get_item_id() or 0
            
            -- Reset throttle if weapon swapped
            if oh_item_id ~= weapon_buff_state.oh.item_id then
                core.log("[Shaman AIO] OH Swapped: " .. weapon_buff_state.oh.item_id .. " -> " .. oh_item_id)
                weapon_buff_state.oh.last_cast = 0
                weapon_buff_state.oh.item_id = oh_item_id
            end

            -- Throttle check
            if weapon_buff_state.oh.last_cast == 0 or (now - weapon_buff_state.oh.last_cast) > 10000 then
                local oh_enchant_id = oh_item:item_enchant_id() or 0
                local has_enchant = oh_item:item_has_enchant()
                local enchant_remains = oh_item:item_enchant_expiration() or 0
                
                -- Detection logic: Success if ID > 0 OR (has_enchant is true AND expiration is significant)
                if oh_enchant_id == 0 and not (has_enchant and enchant_remains > 30) then
                    -- Long throttle check
                    if weapon_buff_state.oh.last_cast == 0 or (now - weapon_buff_state.oh.last_cast) > WEAPON_BUFF_THROTTLE_MS then
                        local oh_buff = menu_number(menu, "weapon_buff_oh", 2)
                        local spell_oh = nil
                        if oh_buff == 1 then spell_oh = spells.rockbiter_weapon
                        elseif oh_buff == 2 then spell_oh = spells.flametongue_weapon
                        elseif oh_buff == 3 then spell_oh = spells.frostbrand_weapon
                        elseif oh_buff == 4 then spell_oh = spells.windfury_weapon
                        end

                        if spell_oh then
                            local can_cast = spell_oh:is_castable({ skip_facing = true })
                            if can_cast then
                                if spell_oh:cast(player) then
                                    weapon_buff_state.oh.last_cast = now
                                    core.log("[Shaman AIO] Applying OH Buff: " .. (oh_buff or "nil"))
                                    return true
                                end
                            else
                                if (now - last_diagnostic_ms) > 10000 then
                                    core.log("[Shaman AIO] OH Buff Not Castable (Buff: " .. tostring(oh_buff) .. ")")
                                    last_diagnostic_ms = now
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- 4. Totems
    if handle_totems(player, menu) then return true end

    -- 5. Lightning Shield (Low Priority)
    if menu_enabled(menu, "use_lightning_shield") and spell_ready(spells.lightning_shield) then
        if buff_missing(player, spells.LIGHTNING_SHIELD_IDS) then
            -- Only cast LS if we don't have Water Shield active (Water Shield has priority)
            if not menu_enabled(menu, "use_water_shield") or buff_missing(player, spells.WATER_SHIELD_IDS) then
                if spells.lightning_shield:is_castable({ skip_facing = true }) and spells.lightning_shield:cast(player) then return true end
            end
        end
    end

    return false
end

-- ============================================================================
-- HEALING LOGIC
-- ============================================================================

local function get_unit_deficit(unit)
    if not unit or not unit:is_alive() then return 0 end
    local max_hp = unit:get_max_health() or 1000
    local cur_hp = unit:get_health() or 1000
    return math.max(0, max_hp - cur_hp)
end

local function cast_heal(menu, spell_name, default_spell, target)
    if menu_enabled(menu, "use_downranking") then
        local deficit = get_unit_deficit(target)
        if deficit > 0 then
            local best = spells:get_best_rank(spell_name, deficit)
            if best and best.spell then
                if best.spell:is_castable() and best.spell:cast(target) then return true end
            end
        end
    end
    -- Fallback: max rank
    if default_spell:is_castable() and default_spell:cast(target) then return true end
    return false
end

local function handle_healing(player, menu)
    local lowest_ally, lowest_hp = find_lowest_hp_ally(player)
    if not lowest_ally then return false end

    -- 1. Nature's Swiftness + Healing Wave (Emergency - instant cast)
    if menu_enabled(menu, "use_natures_swiftness") and spell_ready(spells.natures_swiftness) then
        if lowest_hp <= menu_number(menu, "natures_swiftness_hp", 20) then
            if spells.natures_swiftness:is_castable({ skip_facing = true }) and spells.natures_swiftness:cast(player) then
                if cast_heal(menu, "healing_wave", spells.healing_wave, lowest_ally) then return true end
            end
        end
    end

    -- 2. Lesser Healing Wave (Emergency - fast 1.5s cast, no movement check)
    if lowest_hp <= menu_number(menu, "lesser_healing_wave_hp", 50) then
        if cast_heal(menu, "lesser_healing_wave", spells.lesser_healing_wave, lowest_ally) then return true end
    end

    -- 3. Chain Heal (AoE healing - 2.5s cast, requires stationary)
    if menu_enabled(menu, "enable_aoe") and spell_ready(spells.chain_heal) then
        local aoe_hp = menu_number(menu, "aoe_hp_threshold", 80)
        local min_players = menu_number(menu, "group_aoe_threshold", 3)

        if lowest_hp <= aoe_hp then
            local injured_count = count_injured_allies(player, aoe_hp)
            if injured_count >= min_players then
                if not is_moving(player) then
                    if spells.chain_heal:is_castable() and spells.chain_heal:cast(lowest_ally) then return true end
                end
            end
        end
    end

    -- 4. Healing Wave (Primary single-target heal - 2.5s cast, requires stationary)
    if lowest_hp <= menu_number(menu, "healing_wave_hp", 75) then
        if not is_moving(player) then
            if cast_heal(menu, "healing_wave", spells.healing_wave, lowest_ally) then return true end
        end
    end

    return false
end

local function handle_post_combat_healing(player, menu)
    if player:is_in_combat() or player:is_moving() or player:is_channeling_or_casting() then 
        if player:is_in_combat() then is_post_combat_healing = false end
        return false 
    end
    if rotation_pause.is_eating_or_drinking(player) then 
        is_post_combat_healing = false
        return false 
    end

    local hp = hp_pct(player)
    local min_hp = menu_number(menu, "post_combat_heal_hp", 60)
    local target_hp = menu_number(menu, "post_combat_heal_to_hp", 90)

    -- Trigger the healing loop
    if hp < min_hp then
        is_post_combat_healing = true
    end

    -- Stop the healing loop
    if hp >= target_hp then
        is_post_combat_healing = false
    end

    if is_post_combat_healing then
        -- We use Healing Wave for efficiency out of combat
        if spells.healing_wave:is_castable() and spells.healing_wave:cast(player) then
            core.log("[Shaman AIO] Post-Combat Healing: " .. hp .. "% -> " .. target_hp .. "%")
            return true
        end
    end
    
    return false
end

-- ============================================================================
-- COMBAT ROTATIONS (Spec-Specific)
-- ============================================================================

local function handle_dps(player, target, menu)
    if not target or not target:is_alive() or not target:is_valid_enemy() then return false end
    
    local spec = rotation_logic:get_current_spec()
    local mana = mana_pct(player)
    local target_hp = hp_pct(target)
    
    -- Wand-Style Auto-Attack Filler Check
    if menu_enabled(menu, "use_melee_filler") then
        local fill_mana = menu_number(menu, "melee_filler_mana", 15)
        local fill_hp = menu_number(menu, "melee_filler_hp", 10)
        
        -- If mana is too low OR target is dying, we stick to melee and skip spells
        if (mana < fill_mana or target_hp < fill_hp) and target:distance() <= 5 then
            if not player:is_auto_attacking() then
                auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
            end
            return true -- Melee is the filler now
        end
    end

    -- 1. Elemental Priority
    if spec == "Elemental" then
        -- Totem of Wrath (Elemental Capstone)
        if menu_enabled(menu, "use_totem_of_wrath") and spell_ready(spells.totem_of_wrath) then
            -- We only auto-place ToW if it's explicitly selected in the Fire Totem dropdown
            -- fire_sel: 1=None, 2=ToW, 3=Searing, 4=FireNova, 5=Magma, 6=Flametongue
            local fire_sel = menu_number(menu, "fire_totem_selection", 1)
            
            if fire_sel == 2 then
                local actual = get_active_totem(player, "fire")
                local needs_tow = not actual or actual.name ~= "Totem of Wrath"
                if needs_tow and place_totem("fire", spells.totem_of_wrath, player, "ToW", spells.TOW_BUFF_IDS, 120) then return true end
            end
        end

        -- Elemental Mastery
        if menu_enabled(menu, "use_cooldowns") and menu_enabled(menu, "use_elemental_mastery") and spell_ready(spells.elemental_mastery) then
            if spells.elemental_mastery:is_castable({ skip_facing = true }) and spells.elemental_mastery:cast(player) then return true end
        end

        -- Maintenance: Flame Shock (DoT)
        if spell_ready(spells.flame_shock) and target:distance() <= 20 and debuff_missing(target, spells.FLAME_SHOCK_IDS) then
            if spells.flame_shock:is_castable() and spells.flame_shock:cast(target) then return true end
        end

        -- Chain Lightning (if mana allows)
        if menu_enabled(menu, "use_chain_lightning") and spell_ready(spells.chain_lightning) then
            if mana >= menu_number(menu, "cl_mana_threshold", 20) then
                if spells.chain_lightning:is_castable() and spells.chain_lightning:cast(target) then return true end
            end
        end

        -- Lightning Bolt (Priority Filler for Elemental)
        if menu_enabled(menu, "use_lightning_bolt") and spell_ready(spells.lightning_bolt) then
            if not is_moving(player) then
                if spells.lightning_bolt:is_castable() and spells.lightning_bolt:cast(target) then return true end
            end
        end
        -- Earth Shock (Elemental: Only as movement filler or high-priority burst)
        if menu_enabled(menu, "use_earth_shock") and spell_ready(spells.earth_shock) and target:distance() <= 20 then
            if is_moving(player) or target_hp < 15 then
                if spells.earth_shock:is_castable() and spells.earth_shock:cast(target) then return true end
            end
        end
    end

    -- 2. Enhancement Priority
    if spec == "Enhancement" then
        -- Shamanistic Rage
        if menu_enabled(menu, "use_shamanistic_rage") and spell_ready(spells.shamanistic_rage) then
            if mana <= menu_number(menu, "shamanistic_rage_mana", 30) then
                -- NEW: Check target HP to avoid wasting on dying mobs
                local target_hp_threshold = menu_number(menu, "shamanistic_rage_max_hp", 20)
                if target_hp >= target_hp_threshold then
                    if spells.shamanistic_rage:is_castable({ skip_facing = true }) and spells.shamanistic_rage:cast(player) then return true end
                end
            end
        end

        -- Stormstrike
        if menu_enabled(menu, "use_stormstrike") and spell_ready(spells.stormstrike) then
            if spells.stormstrike:is_castable() and spells.stormstrike:cast(target) then return true end
        end
    end

    -- 3. Shocks (based on shock_mode setting)
    -- Mode 1: Earth Shock Only
    -- Mode 2: Flame Shock Only (DoT)
    -- Mode 3: Flame DoT + Earth Filler (Smart)
    -- Mode 4: Frost Shock (Kiting)
    local shock_mode = menu_number(menu, "shock_mode", 3)
    local es_mode = menu_number(menu, "earth_shock_mode", 1) -- 1=Full, 2=Interrupt, 3=Off
    local can_es = es_mode == 1 or (es_mode == 2 and target:is_casting())
    
    local can_fs = menu_enabled(menu, "use_flame_shock")
    if not menu_enabled(menu, "use_flame_shock_grinding") and not is_elite(target) then
        can_fs = false
    end
    
    if shock_mode == 1 then
        -- Earth Shock Only
        if can_es and spell_ready(spells.earth_shock) and target:distance() <= 20 then
            if spells.earth_shock:is_castable() and spells.earth_shock:cast(target) then return true end
        end
    elseif shock_mode == 2 then
        -- Flame Shock Only - maintain DoT
        if can_fs and spell_ready(spells.flame_shock) and target:distance() <= 20 then
            if debuff_missing(target, spells.FLAME_SHOCK_IDS) then
                if spells.flame_shock:is_castable() and spells.flame_shock:cast(target) then return true end
            end
        end
    elseif shock_mode == 3 then
        -- Smart: Flame Shock DoT first, Earth Shock as filler
        if target:distance() <= 20 then
            if can_fs and spell_ready(spells.flame_shock) and debuff_missing(target, spells.FLAME_SHOCK_IDS) then
                if spells.flame_shock:is_castable() and spells.flame_shock:cast(target) then return true end
            elseif can_es and spell_ready(spells.earth_shock) then
                if spells.earth_shock:is_castable() and spells.earth_shock:cast(target) then return true end
            end
        end
    elseif shock_mode == 4 then
        -- Frost Shock (Kiting)
        if spell_ready(spells.frost_shock) and target:distance() <= 20 then
            if spells.frost_shock:is_castable() and spells.frost_shock:cast(target) then return true end
        end
    end

    -- 4. Filler: Lightning Bolt (Only if mana is sufficient and stationary)
    if menu_enabled(menu, "use_lightning_bolt") and spell_ready(spells.lightning_bolt) then
        if mana >= menu_number(menu, "solo_dps_mana", 40) and not is_moving(player) then
            if spells.lightning_bolt:is_castable() and spells.lightning_bolt:cast(target) then return true end
        end
    end

    return false
end

-- ============================================================================
-- SAFETY & SURVIVAL (Ported from Paladin)
-- ============================================================================

local function same_unit(a, b)
    if not a or not b then return false end
    local ok_a, ga = pcall(function() return a:get_guid() end)
    local ok_b, gb = pcall(function() return b:get_guid() end)
    return ok_a and ok_b and ga == gb
end

local function is_player_targeted(player, enemies)
    if not player or not enemies then return false end
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy.get_target then
            local ok, t = pcall(function() return enemy:get_target() end)
            if ok and t and same_unit(t, player) then return true end
        end
    end
    return false
end

local function count_enemies_targeting_player(player, enemies)
    if not player or not enemies then return 0 end
    local count = 0
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy.get_target then
            local ok, t = pcall(function() return enemy:get_target() end)
            if ok and t and same_unit(t, player) then count = count + 1 end
        end
    end
    return count
end

local function count_melee_enemies_targeting_player(player, enemies, melee_range)
    if not player or not enemies then return 0 end
    local count = 0
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy.get_target and enemy.distance then
            local ok_t, t = pcall(function() return enemy:get_target() end)
            if ok_t and t and same_unit(t, player) then
                local ok_d, d = pcall(function() return enemy:distance() end)
                if ok_d and type(d) == "number" and d <= melee_range then count = count + 1 end
            end
        end
    end
    return count
end

function rotation_logic:try_global_safety(player, menu, enemies)
    local hp = player:get_health_percentage() or 100
    local mana = player:mana_pct() or 100
    local targeted = is_player_targeted(player, enemies)
    local targeters = count_enemies_targeting_player(player, enemies)
    local melee_targeters = count_melee_enemies_targeting_player(player, enemies, 6.0)

    -- 1. Healthstone
    if menu_enabled(menu, "use_healthstones") then
        local threshold = menu_number(menu, "healthstone_hp_pct", 35)
        if hp <= threshold then
            if healthstone_item and healthstone_item:in_inventory() then
                if healthstone_item:use_self_safe("Healthstone") then return true end
            end
        end
    end

    -- 2. HP Potion
    if menu_enabled(menu, "use_hp_potions") then
        local threshold = menu_number(menu, "hp_potion_at", 30)
        if hp <= threshold then
            if izi.use_best_health_potion_safe() then return true end
        end
    end

    -- 3. Mana Potion
    if menu_enabled(menu, "use_mana_potions") then
        local threshold = menu_number(menu, "mana_potion_at", 20)
        if mana <= threshold then
            if izi.use_best_mana_potion_safe() then return true end
        end
    end

    -- 4. Racials
    if menu_enabled(menu, "use_racials") then
        -- Stoneform (Dwarf)
        if menu_enabled(menu, "use_stoneform") and spell_ready(spells.stoneform) then
            local threshold = menu_number(menu, "stoneform_hp_pct", 35)
            if hp <= threshold and (targeted or #enemies >= 1) then
                 if spells.stoneform:cast(player) then return true end
            end
        end

        -- Gift of the Naaru (Draenei)
        if menu_enabled(menu, "use_gift_of_the_naaru") and spell_ready(spells.gift_of_the_naaru) then
            local threshold = menu_number(menu, "gift_of_the_naaru_hp_pct", 40)
            if hp <= threshold and (targeted or #enemies >= 1) then
                if spells.gift_of_the_naaru:cast(player) then return true end
            end
        end

        -- War Stomp (Tauren)
        if spell_ready(spells.war_stomp) and melee_targeters >= 1 then
             if spells.war_stomp:cast() then return true end
        end
        
        -- Blood Fury / Berserking (Orc/Troll)
        if player:is_in_combat() then
            if spell_ready(spells.blood_fury) then if spells.blood_fury:cast(player) then return true end end
            if spell_ready(spells.berserking) then if spells.berserking:cast(player) then return true end end
        end
    end

    return false
end

-- ============================================================================
-- MAIN EXECUTE
-- ============================================================================

function rotation_logic:execute(player, menu, tick_tracker)
    active_tick_tracker = tick_tracker
    local in_combat = player:is_in_combat()
    local target = izi.target()
    
    -- Attack on Target Logic (Checkbox state, toggled via Keybind in main.lua)
    local attack_on_target_enabled = menu_enabled(menu, "attack_on_target")
    
    -- Engagement & Melee Control
    if in_combat or (attack_on_target_enabled and target and target:is_valid_enemy()) then
        handle_auto_attack(player, target, menu)
    end

    if player:is_channeling_or_casting() then return false end

    -- Safety Guards (Healthstones, Potions, Racials)
    local enemies = player:get_enemies_in_range(12, false)
    if rotation_logic:try_global_safety(player, menu, enemies) then return true end
    
    
    -- 1. Maintenance (Buffs & Totems)
    if handle_maintenance(player, menu) then return true end

    -- 2. Healing (Priority in Groups)
    local healing_only = menu_enabled(menu, "healing_only", false)
    if handle_healing(player, menu) then return true end

    -- 3. DPS Rotation
    if not healing_only then
        if in_combat or (attack_on_target_enabled and target and target:is_valid_enemy()) then
            if handle_dps(player, target, menu) then return true end
        end
    end

    -- 4. Out of Combat Healing
    if not in_combat then
        if handle_post_combat_healing(player, menu) then return true end
    end

    return false
end

function rotation_logic:get_current_spec()
    -- Check learned status instead of "ready" to avoid spec swapping during cooldowns
    if spells.mana_tide_totem:is_learned() then return "Restoration" end
    if spells.stormstrike:is_learned() then return "Enhancement" end
    if spells.totem_of_wrath:is_learned() then return "Elemental" end
    return "Leveling"
end

return rotation_logic
