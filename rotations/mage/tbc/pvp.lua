local __object_safety=require("shared/object_safety")
-- ============================================================================
-- Mage PvP Module (TBC Classic)
-- Frost Mage Arena Support - Control > Burst > Survival > Damage
-- Version: 1.0
-- ============================================================================

local pvp = {}

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type pvp_helper
local pvp_helper = require("common/utility/pvp_helper")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

---@type spell_queue
local spell_queue = require("common/modules/spell_queue")

local spells = require("rotations/mage/tbc/spells")

-- ============================================================================
-- SPELL IDS (TBC 2.4.3)
-- ============================================================================

local SPELL_IDS = {
    -- Frost
    frostbolt_r1 = 116,       -- Rank 1 for mana efficiency
    frostbolt_max = 27072,    -- Max rank
    ice_lance = 30455,
    frost_nova = 27088,
    cone_of_cold = 27087,
    blizzard = 27085,
    ice_block = 45438,
    cold_snap = 11958,
    icy_veins = 12472,
    summon_water_elemental = 31687,
    
    -- Utility
    polymorph_r1 = 118,       -- Rank 1 for mana efficiency
    polymorph_max = 12826,    -- Max rank (Sheep)
    counterspell = 2139,
    blink = 1953,
    spellsteal = 30449,
    remove_curse = 475,
    
    -- Arcane
    arcane_explosion = 27082,
    
    -- Pet
    water_elemental_freeze = 33395, -- Pet Freeze ability (Frost Nova)
}

-- Buff/Debuff IDs
local BUFF_IDS = {
    icy_veins = 12472,
    ice_barrier = { 11426, 13031, 13032, 13033, 27134, 33405 },
    ice_block = 45438,
    hypothermia = 41425,       -- Ice Block debuff (can't use again)
    fingers_of_frost = 44544,  -- WotLK, but some servers have it
    frostbite = 12494,         -- Proc root from talents
    shatter = 12982,           -- Shatter talent passive (not a buff)
    presence_of_mind = 12043,
    clearcasting = 12536,
}

local DEBUFF_IDS = {
    polymorph = { 118, 12824, 12825, 12826, 28270, 28271, 28272 },
    frost_nova = { 122, 865, 6131, 10230, 27088 },
    frostbite = 12494,
    winters_chill = 12579,
    cone_of_cold_slow = { 120, 8492, 10159, 10160, 10161, 27087 },
}

-- Mapping of and menu keys to buff IDs for intelligent stealing
local PRIORITY_STEAL_BUFFS = {
    { menu_key = "ss_innervate", ids = { 29166 }, name = "Innervate" },
    { menu_key = "ss_power_infusion", ids = { 10060 }, name = "Power Infusion" },
    { menu_key = "ss_lifebloom", ids = { 33763 }, name = "Lifebloom" },
    { menu_key = "ss_earth_shield", ids = { 32594 }, name = "Earth Shield" },
    { menu_key = "ss_wings", ids = { 31884 }, name = "Avenging Wrath" },
    { menu_key = "ss_bop", ids = { 1022, 5599, 10278 }, name = "BoP" },
    { menu_key = "ss_freedom", ids = { 1044 }, name = "Freedom" },
    { menu_key = "ss_heroism", ids = { 32182, 2825 }, name = "Heroism/Lust" },
    { menu_key = "ss_icy_veins", ids = { 12472 }, name = "Icy Veins" },
    { menu_key = "ss_combustion", ids = { 11129 }, name = "Combustion" },
}

-- ============================================================================
-- STATE TRACKING
-- ============================================================================

local internal_state = {
    last_poly_time = 0,
    last_nova_time = 0,
    last_cs_time = 0,
    last_blink_time = 0,
    last_ice_block_time = 0,
    last_shatter_combo_time = 0,
    last_armor_swap_time = 0,
    poly_target_guid = nil,
    nearby_enemies = {}, -- Track [guid] = { last_seen = time, was_visible = bool }
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function now_ms()
    return core.game_time()
end

---Safe number conversion
---@param v any
---@param fallback number
---@return number
local function num(v, fallback)
    return tonumber(v) or fallback
end

---Safe menu checkbox access
---@param menu table
---@param key string
---@param fallback boolean
---@return boolean
local function menu_enabled(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get_state then
        return fallback
    end
    return menu[key]:get_state() == true
end

---Safe menu slider access
---@param menu table
---@param key string
---@param fallback number
---@return number
local function menu_number(menu, key, fallback)
    if not menu or not menu[key] or not menu[key].get then
        return fallback
    end
    return num(menu[key]:get(), fallback)
end

---Check if spell is learned and ready
---@param spell any
---@return boolean
local function spell_ready(spell)
    if not spell then return false end
    local ok_learned, is_learned = pcall(function() return spell:is_learned() end)
    if not ok_learned or not is_learned then return false end
    local ok_cd, cd_up = pcall(function() return spell:cooldown_up() end)
    if not ok_cd or not cd_up then return false end
    return true
end

local function hp_pct(unit)
    if not unit then return 0 end
    local ok, result = pcall(function()
        return unit:get_health_percentage()
    end)
    return ok and (tonumber(result) or 0) or 0
end

local function mana_pct(player)
    if not player then return 0 end
    local ok, result = pcall(function()
        return player:mana_pct()
    end)
    return ok and (tonumber(result) or 0) or 0
end

local function is_casting(player)
    if not player then return false end
    local ok, result = pcall(function()
        return player:is_channeling_or_casting()
    end)
    return ok and result == true
end

local function is_moving(player)
    if not player then return false end
    local ok, result = pcall(function()
        return player:is_moving()
    end)
    return ok and result == true
end

local function get_distance(unit1, unit2)
    if not unit1 or not unit2 then return 999 end
    local pos1 = unit1:get_position()
    local pos2 = unit2:get_position()
    if not pos1 or not pos2 then return 999 end
    local dx = pos1.x - pos2.x
    local dy = pos1.y - pos2.y
    local dz = pos1.z - pos2.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function has_buff(unit, buff_ids)
    if not unit or not buff_ids then return false end
    local ids = type(buff_ids) == "table" and buff_ids or { buff_ids }
    for _, id in ipairs(ids) do
        local ok, result = pcall(function()
            return unit:buff_up(id)
        end)
        if ok and result == true then return true end
    end
    return false
end

local function has_debuff(unit, debuff_ids)
    if not unit or not debuff_ids then return false end
    local ids = type(debuff_ids) == "table" and debuff_ids or { debuff_ids }
    for _, id in ipairs(ids) do
        local ok, result = pcall(function()
            return unit:debuff_up(id)
        end)
        if ok and result == true then return true end
    end
    return false
end

local function is_frozen(target)
    if not target then return false end
    -- Check for Frost Nova, Frostbite, or Pet Freeze
    return has_debuff(target, DEBUFF_IDS.frost_nova) or
           has_debuff(target, DEBUFF_IDS.frostbite)
end

local function is_player(unit)
    if not unit then return false end
    return pvp_helper:is_player(unit)
end

local function is_enemy_player(unit, player)
    if not unit or not player then return false end
    if not is_player(unit) then return false end
    local ok, result = pcall(function()
        return unit:is_enemy_with(player)
    end)
    return ok and result == true
end

---Check if target is near death for emergency interrupts
---@param target game_object
---@return boolean
local function head_to_head_emergency(target)
    if not target then return false end
    return hp_pct(target) <= 25
end

-- ============================================================================
-- DR TRACKING (Diminishing Returns)
-- Full DR awareness for Nova (ROOT), Sheep (INCAPACITATE), CS (SILENCE)
-- ============================================================================

-- DR category helpers using pvp_helper
local function get_dr_mult(target, cc_flag)
    if not target then return 0 end
    local ok, mult = pcall(function()
        local m, _, _ = pvp_helper:get_cc_reduction_mult(target, cc_flag)
        return m
    end)
    return ok and (mult or 1.0) or 1.0
end

local function is_dr_immune(target, cc_flag)
    if not target then return true end
    local ok, immune = pcall(function()
        local i, _, _ = pvp_helper:is_cc_immune(target, cc_flag)
        return i
    end)
    return ok and immune == true
end

-- Specific DR checks
local function get_poly_dr_mult(target)
    return get_dr_mult(target, pvp_helper.cc_flags.INCAPACITATE)
end

local function is_poly_immune(target)
    return is_dr_immune(target, pvp_helper.cc_flags.INCAPACITATE)
end

local function get_nova_dr_mult(target)
    return get_dr_mult(target, pvp_helper.cc_flags.ROOT)
end

local function is_nova_immune(target)
    return is_dr_immune(target, pvp_helper.cc_flags.ROOT)
end

local function get_silence_dr_mult(target)
    return get_dr_mult(target, pvp_helper.cc_flags.SILENCE)
end

local function is_silence_immune(target)
    return is_dr_immune(target, pvp_helper.cc_flags.SILENCE)
end

local function is_target_cced(target)
    if not target then return false end
    local ok, result = pcall(function()
        local is_cced, remaining_ms, _ = pvp_helper:is_crowd_controlled(target, pvp_helper.cc_flags.ANY_BUT_SLOW)
        return is_cced == true and (remaining_ms or 0) > 500
    end)
    return ok and result == true
end

--- Check if a friendly player already has CC on the target (overlap awareness)
--- Returns true if target is already CC'd by someone else and has > 2s remaining
local function is_friendly_cc_active(target)
    if not target then return false end
    local ok, result = pcall(function()
        local is_cced, remaining_ms, _ = pvp_helper:is_crowd_controlled(target, pvp_helper.cc_flags.INCAPACITATE)
        return is_cced == true and (remaining_ms or 0) > 2000
    end)
    return ok and result == true
end

-- ============================================================================
-- SPELL CASTING HELPERS
-- ============================================================================

local function queue_spell(spell_id, target, priority, msg)
    if not spell_id or not target then return false end
    spell_queue:queue_spell_target(spell_id, target, priority or 5, msg or "PvP Spell")
    return true
end

local function queue_spell_self(spell_id, player, priority, msg)
    if not spell_id or not player then return false end
    spell_queue:queue_spell_target(spell_id, player, priority or 5, msg or "PvP Self Spell")
    return true
end

local function can_cast(spell)
    if not spell then return false end
    local ok, result = pcall(function()
        return spell:is_learned() and spell:cooldown_up()
    end)
    return ok and result == true
end

-- ============================================================================
-- DEFENSIVE LOGIC
-- ============================================================================

-- = ===========================================================================
-- DEFENSIVE LOGIC
-- ============================================================================

function pvp.handle_defensives(state, menu)
    local player = state.player
    if not player or state.is_casting then return false end
    
    local my_hp = state.player_hp
    local now = state.now
    
    -- 1. ICE BLOCK - Emergency (Priority 8)
    local ice_block_threshold = 15
    if menu.ice_block_hp_threshold and menu.ice_block_hp_threshold.get then
        ice_block_threshold = tonumber(menu.ice_block_hp_threshold:get()) or 15
    end
    if my_hp <= ice_block_threshold then
        if spells.ice_block and can_cast(spells.ice_block) then
            if not has_buff(player, BUFF_IDS.hypothermia) then
                if (now - internal_state.last_ice_block_time) > 30000 then
                    internal_state.last_ice_block_time = now
                    return queue_spell_self(spells.ice_block:id(), player, 8, "[PVP] Ice Block!")
                end
            end
        end
    end
    
    -- 2. BLINK - Escape melee/roots (Priority 7)
    if my_hp <= 40 or pvp_helper:is_crowd_controlled(player, pvp_helper.cc_flags.ROOT) then
        if spells.blink and can_cast(spells.blink) then
            if (now - internal_state.last_blink_time) > 15000 then
                -- Skip if moving to avoid wasting blink
                if not state.is_moving or my_hp <= 25 then
                    internal_state.last_blink_time = now
                    return queue_spell_self(spells.blink:id(), player, 7, "[PVP] Blink!")
                end
            end
        end
    end
    
    -- 3. COLD SNAP - Reset Ice Block / Icy Veins if desperate
    if my_hp <= 20 then
        if spells.cold_snap and can_cast(spells.cold_snap) then
            -- Only if Ice Block is on CD
            if spells.ice_block and not can_cast(spells.ice_block) then
                return queue_spell_self(spells.cold_snap:id(), player, 8, "[PVP] Cold Snap Reset!")
            end
        end
    end
    
    -- 4. FROST NOVA - Kite melee (Priority 6) - WITH DR AWARENESS
    local ok_enemies, enemies = pcall(function()
        return unit_helper:get_enemy_list_around(player:get_position(), 10, false, false)
    end)
    enemies = ok_enemies and enemies or {}
    local melee_close = false
    local melee_target = nil
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if is_player(enemy) and get_distance(player, enemy) <= 8 then
            melee_close = true
            melee_target = enemy
            break
        end
    end
    
    if melee_close and my_hp <= 60 then
        if spells.frost_nova and can_cast(spells.frost_nova) then
            -- DR Awareness: Skip Nova if target is ROOT-immune
            local dr_ok = true
            if menu_enabled(menu, "pvp_dr_awareness", true) and melee_target then
                if is_nova_immune(melee_target) or get_nova_dr_mult(melee_target) < 0.25 then
                    dr_ok = false
                end
            end
            if dr_ok and (now - internal_state.last_nova_time) > 5000 then
                internal_state.last_nova_time = now
                return queue_spell_self(spells.frost_nova:id(), player, 6, "[PVP] Frost Nova Kite!")
            end
        end
    end
    
    return false
end

-- ============================================================================
-- CONTROL LOGIC (CC)
-- ============================================================================

function pvp.handle_control(state, menu)
    local player = state.player
    local target = state.target
    if not player or state.is_casting then return false end
    
    local now = state.now
    
    -- FOCUS CC SUPPORT: Check if we should use Focus instead of Target
    local cc_target = target
    if menu_enabled(menu, "pvp_focus_cc", false) then
        local focus = state.focus
        
        if focus and focus:is_alive() and focus:is_enemy_with(player) then
            local dist = get_distance(player, focus)
            if dist <= 30 then
                cc_target = focus
            end
        end
    end
    
    if not cc_target or not is_player(cc_target) then return false end

    -- 1. COUNTERSPELL - Interrupt casts (Priority 7) - WITH DR AWARENESS
    local use_cs = menu_enabled(menu, "use_counterspell", false)
    if use_cs then
        if spells.counterspell and can_cast(spells.counterspell) then
            -- DR Awareness: Skip if target is silence-immune
            local cs_dr_ok = true
            if menu_enabled(menu, "pvp_dr_awareness", true) then
                if is_silence_immune(cc_target) then cs_dr_ok = false end
            end
            if cs_dr_ok then
                local ok_casting, is_target_casting = pcall(function()
                    return cc_target:is_casting_spell()
                end)
                if ok_casting and is_target_casting then
                    local ok_int, interruptable = pcall(function()
                        return cc_target:is_active_spell_interruptable()
                    end)
                    if ok_int and interruptable == true then
                        local ok_pct, cast_pct = pcall(function()
                            return cc_target:get_cast_pct()
                        end)
                        cast_pct = ok_pct and (tonumber(cast_pct) or 0) or 0
                        
                        local threshold = menu_number(menu, "pvp_interrupt_pct", 75)
                        
                        if cast_pct >= threshold or head_to_head_emergency(cc_target) then
                            if (now - internal_state.last_cs_time) > 2000 then
                                internal_state.last_cs_time = now
                                return queue_spell(spells.counterspell:id(), cc_target, 7, "[PVP] Counterspell!")
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- 2. POLYMORPH - CC target (Priority 5) - WITH DR + FRIENDLY OVERLAP AWARENESS
    local use_poly = menu_enabled(menu, "use_polymorph", false)
    if use_poly then
        if spells.polymorph and can_cast(spells.polymorph) then
            -- Skip if target already CC'd by a friendly
            local overlap = false
            if menu_enabled(menu, "pvp_dr_awareness", true) then
                overlap = is_friendly_cc_active(cc_target)
            end
            if not overlap and not is_target_cced(cc_target) and not is_poly_immune(cc_target) then
                local dr_mult = get_poly_dr_mult(cc_target)
                if dr_mult >= 0.5 then
                    if (now - internal_state.last_poly_time) > 1500 then
                        internal_state.last_poly_time = now
                        local poly_id = state.player_mana < 30 and SPELL_IDS.polymorph_r1 or spells.polymorph:id()
                        return queue_spell(poly_id, cc_target, 5, "[PVP] Polymorph!")
                    end
                end
            end
        end
    end
    
    return false
end

---Handle Smart Spellsteal
---@param state table
---@param menu table
---@return boolean
function pvp.handle_spellsteal(state, menu)
    local player = state.player
    local target = state.target
    if not player or not target or state.is_casting then return false end
    if not menu_enabled(menu, "pvp_spellsteal_enabled", true) then return false end
    if not spell_ready(spells.spellsteal) then return false end
    
    -- Mana Safety: Spellsteal is expensive (around 500-600 mana)
    if state.player_mana < 15 then return false end
    
    -- Scan prioritize buffs
    for _, buff_cfg in ipairs(PRIORITY_STEAL_BUFFS) do
        if menu_enabled(menu, buff_cfg.menu_key, true) then
            for _, id in ipairs(buff_cfg.ids) do
                local ok, has_it = pcall(function() return target:buff_up(id) end)
                if ok and has_it then
                    return queue_spell(spells.spellsteal:id(), target, 6, "[PVP] Stealing " .. buff_cfg.name)
                end
            end
        end
    end
    
    return false
end

-- ============================================================================
-- BURST LOGIC (Shatter Combo)
-- ============================================================================

function pvp.handle_burst(state, menu)
    local player = state.player
    local target = state.target
    if not player or not target or state.is_casting then return false end
    
    -- Check master burst toggle
    if menu.enable_pvp_burst and menu.enable_pvp_burst.get_state then
        if not menu.enable_pvp_burst:get_state() then return false end
    end
    
    local now = state.now
    local target_frozen = is_frozen(target)
    
    -- 1. ICY VEINS - Pop on go (Priority 6)
    local use_iv = false
    if menu.use_icy_veins and menu.use_icy_veins.get_state then
        use_iv = menu.use_icy_veins:get_state()
    end
    if use_iv then
        if spells.icy_veins and can_cast(spells.icy_veins) then
            -- Pop when target is frozen or low HP
            if target_frozen or hp_pct(target) <= 50 then
                return queue_spell_self(spells.icy_veins:id(), player, 6, "[PVP] Icy Veins Burst!")
            end
        end
    end
    
    -- 2. SHATTER COMBO: Ice Lance on frozen target (Priority 5)
    if target_frozen then
        if (now - internal_state.last_shatter_combo_time) > 1500 then
            -- Ice Lance is instant and crits on frozen targets
            if spells.ice_lance and can_cast(spells.ice_lance) then
                internal_state.last_shatter_combo_time = now
                return queue_spell(spells.ice_lance:id(), target, 5, "[PVP] Shatter Ice Lance!")
            end
        end
    end
    
    -- 3. Moving DPS: Ice Lance / Fire Blast
    if state.is_moving then
        if spells.ice_lance and can_cast(spells.ice_lance) then
            return queue_spell(spells.ice_lance:id(), target, 3, "[PVP] Moving Ice Lance")
        end
        if spells.fire_blast and can_cast(spells.fire_blast) then
            return queue_spell(spells.fire_blast:id(), target, 3, "[PVP] Moving Fire Blast")
        end
    end
    
    return false
end

-- ============================================================================
-- FILLER DAMAGE
-- ============================================================================

function pvp.handle_filler(state, menu)
    local player = state.player
    local target = state.target
    if not player or not target then return false end
    if state.is_casting or state.is_moving then return false end
    
    local my_mana = state.player_mana
    
    -- Use Rank 1 Frostbolt for mana efficiency when low
    if my_mana < 30 then
        return queue_spell(SPELL_IDS.frostbolt_r1, target, 2, "[PVP] R1 Frostbolt (mana)")
    end
    
    -- Max rank Frostbolt
    if spells.frostbolt and can_cast(spells.frostbolt) then
        return queue_spell(spells.frostbolt:id(), target, 2, "[PVP] Frostbolt")
    end
    
    return false
end

-- ============================================================================
-- ANTI-STEALTH REACTIVE AE
-- ============================================================================

---Track last known target for vanish detection
local last_known_target_guid = nil
local last_known_target_time = 0

---Handle Reactive AE for stealth detection
---@param state table
---@param menu table
---@return boolean
function pvp.handle_anti_stealth(state, menu)
    if not menu_enabled(menu, "pvp_anti_stealth", true) then return false end
    local player = state.player
    if not player or state.is_casting then return false end
    
    local now = state.now
    local target = state.target
    
    -- Track last known target
    if target and is_player(target) and target:is_alive() then
        local ok_guid, guid = pcall(function() return target:get_guid() end)
        if ok_guid and guid then
            last_known_target_guid = guid
            last_known_target_time = now
        end
    end
    
    -- Vanish detection: had a target recently but now it's gone
    if not target and last_known_target_guid 
       and (now - last_known_target_time) < 1500
       and (now - last_known_target_time) > 200 then
        
        -- Before using AE, check for CC'd units nearby to avoid breaking sheep
        local units = izi.get_units(15)
        local cc_nearby = false
        for _, unit in __object_safety.live_ipairs(units) do
            if is_target_cced(unit) then
                cc_nearby = true
                break
            end
        end
        
        if not cc_nearby then
            -- Rank 1 AE (spell ID 1449)
            last_known_target_guid = nil
            return queue_spell_self(1449, player, 6, "[ELITE] Anti-Stealth AE!")
        end
    end
    
    return false
end

-- ============================================================================
-- ADAPTIVE ARMOR SWAPPING (10s THROTTLE)
-- ============================================================================

-- Melee classes: Warrior(1), Paladin(2), Rogue(4)
-- Hybrid melee: Druid(11) in feral form, Enhancement Shaman(7)
local MELEE_CLASS_IDS = { [1] = true, [2] = true, [4] = true }

---Determine and swap armor based on enemy composition
---@param state table
---@param menu table
---@return boolean
function pvp.handle_armor_swap(state, menu)
    if not menu_enabled(menu, "pvp_armor_swap", true) then return false end
    local player = state.player
    if not player or state.is_casting then return false end
    
    local now = state.now
    
    -- 10-second throttle to prevent GCD flickering
    if (now - (internal_state.last_armor_swap_time or 0)) < 10000 then return false end
    
    local ok_units, enemies = pcall(function() return izi.get_units(35) end)
    if not ok_units or not enemies then return false end
    
    local melee_nearby = false
    local any_enemy = false
    local all_casters = true
    
    for _, unit in __object_safety.live_ipairs(enemies) do
        local ok_enemy, is_enemy = pcall(function()
            return unit:is_enemy_with(player) and is_player(unit) and unit:is_alive()
        end)
        if ok_enemy and is_enemy then
            any_enemy = true
            local ok_class, class_id = pcall(function() return unit:get_class() end)
            if ok_class and class_id then
                local dist = get_distance(player, unit)
                
                if MELEE_CLASS_IDS[class_id] then
                    all_casters = false
                    if dist < 20 then melee_nearby = true end
                elseif class_id == 11 then
                    -- Druid: check power type for feral (1=Rage, 3=Energy = melee form)
                    local ok_pt, power_type = pcall(function() return unit:get_power_type() end)
                    if ok_pt and (power_type == 1 or power_type == 3) then
                        all_casters = false
                        if dist < 20 then melee_nearby = true end
                    end
                elseif class_id == 7 then
                    -- Shaman: check if enhancement (close range)
                    local dist_s = get_distance(player, unit)
                    if dist_s < 12 then
                        all_casters = false
                        melee_nearby = true
                    end
                end
            end
        end
    end
    
    if not any_enemy then return false end
    
    -- Swap to Ice Armor if melee is nearby
    if melee_nearby then
        local has_ice = has_buff(player, spells.ICE_ARMOR_BUFF_IDS)
        if not has_ice and spells.ice_armor and can_cast(spells.ice_armor) then
            internal_state.last_armor_swap_time = now
            return queue_spell_self(spells.ice_armor:id(), player, 4, "[ELITE] Ice Armor (Melee nearby)")
        end
    -- Swap to Molten Armor if all enemies are casters
    elseif all_casters then
        local has_molten = has_buff(player, spells.MOLTEN_ARMOR_BUFF_IDS)
        if not has_molten and spells.molten_armor and can_cast(spells.molten_armor) then
            internal_state.last_armor_swap_time = now
            return queue_spell_self(spells.molten_armor:id(), player, 4, "[ELITE] Molten Armor (Casters only)")
        end
    end
    
    return false
end

-- ============================================================================
-- PET-SYNC SHATTER MASTERY
-- ============================================================================

---Use Pet Freeze mid-Frostbolt cast for guaranteed Shatter crit
---@param state table
---@param menu table
---@return boolean
function pvp.handle_pet_sync_shatter(state, menu)
    if not menu_enabled(menu, "pvp_pet_sync_shatter", true) then return false end
    local player = state.player
    local target = state.target
    if not player or not target then return false end
    
    -- GATE: Only use shatter during burst mode OR if target is in kill range (≤ 35% HP)
    local burst_on = false
    if menu.enable_pvp_burst and menu.enable_pvp_burst.get_state then
        burst_on = menu.enable_pvp_burst:get_state()
    end
    local kill_window = hp_pct(target) <= 35
    if not burst_on and not kill_window then return false end
    
    -- Only relevant while we are casting Frostbolt
    if not state.is_casting then return false end
    
    -- Check if the target is already frozen (no point freezing again)
    if is_frozen(target) then return false end
    
    -- Check cast progress: we want to Freeze when Frostbolt is 60-90% done
    local ok_pct, cast_pct = pcall(function() return player:get_cast_pct() end)
    if not ok_pct or not cast_pct then return false end
    cast_pct = tonumber(cast_pct) or 0
    
    if cast_pct < 60 or cast_pct > 90 then return false end
    
    -- Get the pet
    local ok_pet, pet = pcall(function() return player:get_pet() end)
    if not ok_pet or not pet or not pet:is_alive() then return false end
    
    -- Use Pet Freeze (Water Elemental Nova, spell ID 33395)
    local ok_cast = pcall(function()
        spell_queue:queue_spell_target(SPELL_IDS.water_elemental_freeze, target, 7, "[ELITE] Pet Freeze Shatter!")
    end)
    
    return ok_cast == true
end

-- ============================================================================
-- AUTO PVP TRINKET
-- ============================================================================

---Use PvP Trinket if crowd controlled
---@param state table
---@param menu table
---@return boolean
function pvp.handle_pvp_trinket(state, menu)
    if not menu_enabled(menu, "pvp_trinket_enabled", false) then return false end
    local player = state.player
    if not player or not player:is_alive() then return false end

    local now = state.now

    -- Use pvp_helper's precise CC tracking
    local is_cc, remain, _ = pvp_helper:is_crowd_controlled(player, pvp_helper.cc_flags.ANY_BUT_SLOW)

    if is_cc and remain > 2000 then
        -- Assume standard PvP trinket mapping. Often mapped to a specialized spell, or macro.
        -- But for the SDK, we typically trigger dynamic items if they exist.
        -- Since item ids vary by rank/faction (Insignia of the Alliance/Horde),
        -- we simulate a generic spell cast or trigger.
        -- Let's check for standard PvP trinket spell IDs.
        local PVP_TRINKET_SPELLS = { 42292 } -- Standard PvP Trinket spell effect
        for _, sid in ipairs(PVP_TRINKET_SPELLS) do
            local ok, trinket_spell = pcall(function() return izi.spell(sid) end)
            if ok and trinket_spell and spell_ready(trinket_spell) then
                return queue_spell_self(sid, player, 9, "[PVP] PvP Trinket Auto-used!")
            end
        end
    end
    
    return false
end

-- ============================================================================
-- AUTO KITE COMBO
-- ============================================================================

---Executes Nova -> Blink -> Bolt sequence
---@param state table
---@param menu table
---@return boolean
function pvp.handle_kite_combo(state, menu)
    if not menu_enabled(menu, "pvp_kite_combo", true) then return false end
    local player = state.player
    if not player or state.is_casting then return false end

    -- Condition: We recently used Frost Nova (within last 1.5s)
    local now = state.now
    if (now - internal_state.last_nova_time) < 1500 then
        -- Attempt to blink away if off cooldown
        if spell_ready(spells.blink) and not state.is_moving then
            internal_state.last_blink_time = now
            return queue_spell_self(spells.blink:id(), player, 7, "[PVP] Kite Combo: Blink!")
        end
        -- If we already blinked or it's on CD, prepare to cast Frostbolt
        -- Assuming moving away from targets
        local target = state.target
        if target and is_frozen(target) and not state.is_moving then
            if spell_ready(spells.frostbolt) then
                return queue_spell(spells.frostbolt:id(), target, 4, "[PVP] Kite Combo: Frostbolt")
            end
        end
    end

    return false
end

-- ============================================================================
-- CONE OF COLD FINISHER
-- ============================================================================

---Uses Cone of Cold to finish off targets in kill windows, avoiding breaking CC
---@param state table
---@param menu table
---@return boolean
function pvp.handle_coc_finisher(state, menu)
    if not menu_enabled(menu, "pvp_coc_finisher", true) then return false end
    local player = state.player
    local target = state.target
    if not player or not target then return false end

    -- Verify Cone of Cold is ready
    if not spells.cone_of_cold or not spell_ready(spells.cone_of_cold) then return false end

    -- Check kill window condition (≤ 30% HP)
    if hp_pct(target) > 30 then return false end

    -- Check distance (CoC is generally a ~10-11 yard frontal cone)
    local dist = get_distance(player, target)
    if dist > 10 then return false end
    
    -- CC Safety Check: Ensure no CC'd targets are close to the primary target
    local ok_enemies, enemies = pcall(function()
        return unit_helper:get_enemy_list_around(player:get_position(), 15, false, false)
    end)
    enemies = ok_enemies and enemies or {}

    for _, enemy in __object_safety.live_ipairs(enemies) do
         if is_target_cced(enemy) and (not __object_safety.same(enemy,target)) then
            -- A friendly CC'd target is nearby, abort CoC to avoid breaking
            return false
         end
    end

    return queue_spell(spells.cone_of_cold:id(), target, 7, "[ELITE] CoC Finisher!")
end

-- ============================================================================
-- MAIN PVP EXECUTE
-- ============================================================================

function pvp.execute(state, menu)
    local player = state.player
    if not player then return false end
    
    local burst_enabled = false
    if menu.enable_pvp_burst and menu.enable_pvp_burst.get_state then
        burst_enabled = menu.enable_pvp_burst:get_state()
    end

    -- Run if we are in a PvP scenario OR if Burst is manually enabled
    if not pvp_helper:is_pvp_scenario() and not burst_enabled then
        return false
    end
    
    -- Priority order: Trinket > Armor > Anti-Stealth > Defensives > Control > Kite > Shatter > CoC > Burst > Filler
    if pvp.handle_pvp_trinket(state, menu) then return true end
    if pvp.handle_armor_swap(state, menu) then return true end
    if pvp.handle_anti_stealth(state, menu) then return true end
    if pvp.handle_defensives(state, menu) then return true end
    
    if state.target then
        if pvp.handle_kite_combo(state, menu) then return true end
        if pvp.handle_pet_sync_shatter(state, menu) then return true end
        if pvp.handle_control(state, menu) then return true end
        if pvp.handle_coc_finisher(state, menu) then return true end
        if pvp.handle_burst(state, menu) then return true end
        if pvp.handle_filler(state, menu) then return true end
    end
    
    return false
end

return pvp
