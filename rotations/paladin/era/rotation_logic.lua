local __object_safety=require("shared/object_safety")
-- ============================================================================
local performance = require("shared/rotation_performance")
-- Paladin Unified Leveling Rotation (Classic ERA)
-- DPS (Ret), Tank (Prot), Healer (Holy) via toggles
-- ============================================================================

local rotation_logic = {}

---@type enums
local enums = require("common/enums")

---@type izi_sdk
local izi = require("common/izi_sdk")

---@type auto_attack_helper
local auto_attack_helper = require("common/utility/auto_attack_helper")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

local spells = require("rotations/paladin/era/spells")
local dispel_whitelist = require("rotations/paladin/shared/dispel_whitelist")

-- See `.api/game_object.lua` for creature_type ids (Demon=3, Undead=6).
local CREATURE_TYPE_UNDEAD = (enums and enums.creature_type and enums.creature_type.UNDEAD) or 6
local CREATURE_TYPE_DEMON = (enums and enums.creature_type and enums.creature_type.DEMON) or 3

local last_buff_check_ms = 0
local BUFF_CHECK_INTERVAL_MS = 3500

local last_heal_cast_ms = 0
local HEAL_THROTTLE_MS = 100

local last_valid_swing_speed = nil
local last_seal_cast_ms = 0
local SEAL_THROTTLE_MS = 1200

local seal_regen_mode = false
local seal_regen_until_ms = 0
local SEAL_REGEN_STICKY_MS = 8000
local SEAL_REGEN_RELEASE_MANA_MIN_PCT = 25
local SEAL_REGEN_RELEASE_MANA_DELTA_PCT = 10

local last_holy_shield_ms = 0
local HOLY_SHIELD_RETRY_MS = 800

local last_cleanse_ms_by_guid = {}
local CLEANSE_THROTTLE_MS = 1200

---@param menu table|nil
---@param state table|nil
---@param key string
---@param default boolean|nil
---@return boolean
local function bool_opt(menu, state, key, default)
    if state and state[key] ~= nil then
        return state[key] == true
    end
    if menu and menu[key] and menu[key].get_state then
        return menu[key]:get_state() == true
    end
    return default == true
end

---@param menu table|nil
---@param key string
---@param default number|nil
---@return number
local function num_opt(menu, key, default)
    if menu and menu[key] and menu[key].get then
        local v = menu[key]:get()
        if type(v) == "number" then
            return v
        end
    end
    return default or 0
end

local function now_ms()
    if izi.now_ms then
        return izi.now_ms()
    end
    return math.floor((core.time() or 0) * 1000 + 0.5)
end

local last_log_times = {}
local function log_throttled(menu, key, interval_ms, message, role)
    if not bool_opt(menu, nil, "paladin_detailed_log_enabled", false) then
        return
    end
    local now = now_ms()
    if (now - (last_log_times[key] or 0)) < interval_ms then
        return
    end

    local role_str = role or "Generic"
    core.log(string.format("[%s] %s", role_str, message))
    last_log_times[key] = now
end

---@param now integer
---@return boolean
local function seal_throttle_ready(now)
    return (now - (last_seal_cast_ms or 0)) >= SEAL_THROTTLE_MS
end

---@param player game_object
---@return number
local function get_swing_speed(player)
    if not player or not player.get_attack_speed then
        return last_valid_swing_speed or 0
    end
    local ok, speed = pcall(function()
        return player:get_attack_speed()
    end)
    if not ok or type(speed) ~= "number" or speed <= 0 then
        return last_valid_swing_speed or 0
    end
    if speed > 8.0 then
        return last_valid_swing_speed or 0
    end
    last_valid_swing_speed = speed
    return speed
end

---@param unit game_object|nil
---@param buff_ids integer[]
---@return boolean
local function has_any_buff(unit, buff_ids)
    if not unit or not unit:is_alive() then
        return false
    end
    for _, id in ipairs(buff_ids or {}) do
        if unit:buff_up(id) then
            return true
        end
    end
    return false
end

-- Backwards-compat: keep the old helper name but use izi aura checks (no raw buff scans).
---@param unit game_object|nil
---@param ids integer[]|nil
---@return boolean
local function has_any_buff_by_buffs(unit, ids)
    return has_any_buff(unit, ids or {})
end

---@param now integer
local function enter_seal_regen_mode(now)
    seal_regen_mode = true
    seal_regen_until_ms = now + SEAL_REGEN_STICKY_MS
end

---@param now integer
---@param mana number
---@param mana_very_low number
---@param wisdom_up boolean
---@return boolean
local function seal_regen_active(now, mana, mana_very_low, wisdom_up)
    if wisdom_up and mana <= mana_very_low then
        enter_seal_regen_mode(now)
    end

    if seal_regen_mode ~= true then
        return false
    end

    local release_mana = math.max(SEAL_REGEN_RELEASE_MANA_MIN_PCT, mana_very_low + SEAL_REGEN_RELEASE_MANA_DELTA_PCT)
    if now >= (seal_regen_until_ms or 0) and mana >= release_mana then
        seal_regen_mode = false
        return false
    end

    return true
end

---@param unit game_object|nil
---@return string|nil
local function unit_guid_key(unit)
    if not unit or not unit.get_guid then
        return nil
    end
    local ok, guid = pcall(function()
        return unit:get_guid()
    end)
    if ok and guid then
        return tostring(guid)
    end
    return tostring(unit)
end

---@param unit game_object|nil
---@param now integer
---@return boolean
local function cleanse_throttle_ready(unit, now)
    local key = unit_guid_key(unit)
    if not key then
        return true
    end
    local last = last_cleanse_ms_by_guid[key] or 0
    return (now - last) >= CLEANSE_THROTTLE_MS
end

---@param unit game_object|nil
---@param now integer
local function mark_cleanse_cast(unit, now)
    local key = unit_guid_key(unit)
    if not key then
        return
    end
    last_cleanse_ms_by_guid[key] = now
end

---@param player game_object
---@return boolean
local function any_seal_up(player)
    return has_any_buff(player, spells.SEAL_OF_RIGHTEOUSNESS_IDS)
        or has_any_buff(player, spells.SEAL_OF_COMMAND_IDS)
        or has_any_buff(player, spells.SEAL_OF_WISDOM_IDS)
        or has_any_buff(player, spells.SEAL_OF_LIGHT_IDS)
        or has_any_buff(player, spells.SEAL_OF_JUSTICE_IDS)
        or has_any_buff(player, spells.SEAL_OF_THE_CRUSADER_IDS)
end

local MANUAL_SEAL_KEYS = {
    "righteousness",
    "command",
    "wisdom",
    "light",
    "justice",
    "crusader"
}

local MANUAL_SEAL_MAP = {
    righteousness = { spell = function() return spells.seal_of_righteousness end, ids = function() return spells.SEAL_OF_RIGHTEOUSNESS_IDS end },
    command = { spell = function() return spells.seal_of_command end, ids = function() return spells.SEAL_OF_COMMAND_IDS end },
    wisdom = { spell = function() return spells.seal_of_wisdom end, ids = function() return spells.SEAL_OF_WISDOM_IDS end },
    light = { spell = function() return spells.seal_of_light end, ids = function() return spells.SEAL_OF_LIGHT_IDS end },
    justice = { spell = function() return spells.seal_of_justice end, ids = function() return spells.SEAL_OF_JUSTICE_IDS end },
    crusader = { spell = function() return spells.seal_of_the_crusader end, ids = function() return spells.SEAL_OF_THE_CRUSADER_IDS end }
}

local manual_seal_tracker = {
    last_choice = nil,
    last_states = {}
}

---@param state table|nil
---@param now integer
---@return string|nil
local function manual_seal_choice(state, now)
    local sel = state and state.seal_selection or nil
    if not (sel and sel.enabled == true) then
        manual_seal_tracker.last_choice = nil
        manual_seal_tracker.last_states = {}
        return nil
    end

    local any = false
    for _, key in ipairs(MANUAL_SEAL_KEYS) do
        local cur = sel[key] == true
        any = any or cur
        local prev = manual_seal_tracker.last_states[key] == true
        if cur and not prev then
            manual_seal_tracker.last_choice = key
            manual_seal_tracker.last_choice_ms = now
        end
        manual_seal_tracker.last_states[key] = cur
    end

    if not any then
        manual_seal_tracker.last_choice = nil
        return nil
    end

    if manual_seal_tracker.last_choice and sel[manual_seal_tracker.last_choice] == true then
        return manual_seal_tracker.last_choice
    end

    for _, key in ipairs(MANUAL_SEAL_KEYS) do
        if sel[key] == true then
            manual_seal_tracker.last_choice = key
            return key
        end
    end

    return nil
end

---@param player game_object
---@param choice string
---@param now integer
---@return boolean
local function try_maintain_manual_seal(player, choice, now)
    local entry = choice and MANUAL_SEAL_MAP[choice] or nil
    if not entry then
        return false
    end

    local seal_spell = entry.spell and entry.spell() or nil
    local seal_ids = entry.ids and entry.ids() or nil
    if not (seal_spell and seal_ids and seal_spell.is_learned and seal_spell:is_learned()) then
        return false
    end

    local gcd_remains = player:gcd_remains() or 0
    if gcd_remains > 0 then
        return false
    end

    if not seal_throttle_ready(now) then
        return false
    end

    if not has_any_buff(player, seal_ids) then
        if seal_spell:is_castable({ skip_facing = true }) then
            if seal_spell:cast(player) then
                last_seal_cast_ms = now
                if seal_ids == spells.SEAL_OF_WISDOM_IDS then
                    enter_seal_regen_mode(now)
                end
                return true
            end
        end
    end

    return false
end

---@param unit game_object|nil
---@return boolean
local function is_unit_undead_or_demon(unit)
    if not unit or not unit:is_alive() or not unit.get_creature_type then
        return false
    end
    local ok_ct, ct = pcall(function()
        return unit:get_creature_type()
    end)
    if not ok_ct or not ct then
        return false
    end
    return ct == CREATURE_TYPE_UNDEAD or ct == CREATURE_TYPE_DEMON
end

---@param unit game_object|nil
---@param debuff_ids integer[]
---@return boolean
local function has_any_debuff(unit, debuff_ids)
    if not unit or not unit:is_alive() then
        return false
    end
    for _, id in ipairs(debuff_ids or {}) do
        local ok, up = pcall(function()
            return unit:debuff_up(id)
        end)
        if ok and up == true then
            return true
        end
    end
    return false
end

---@param target game_object|nil
---@param desired_debuff_ids integer[]|nil
---@return boolean
local function target_has_other_judgement_active(target, desired_debuff_ids)
    if not (target and desired_debuff_ids) then
        return false
    end

    if has_any_debuff(target, desired_debuff_ids) then
        return false
    end

    if desired_debuff_ids ~= spells.JOW_DEBUFF_IDS and has_any_debuff(target, spells.JOW_DEBUFF_IDS) then
        return true
    end
    if desired_debuff_ids ~= spells.JOTC_DEBUFF_IDS and has_any_debuff(target, spells.JOTC_DEBUFF_IDS) then
        return true
    end
    if desired_debuff_ids ~= spells.JOL_DEBUFF_IDS and has_any_debuff(target, spells.JOL_DEBUFF_IDS) then
        return true
    end

    return false
end

---@param unit game_object|nil
---@param debuff_ids integer[]
---@return boolean is_active
---@return number remaining_ms
local function get_any_debuff_status(unit, debuff_ids)
    if not unit or not unit:is_alive() then
        return false, 0
    end

    -- Primary: buff_manager
    if buff_manager and buff_manager.get_debuff_data then
        local ok_bm, data = pcall(function()
            return buff_manager:get_debuff_data(unit, debuff_ids)
        end)
        if ok_bm and data and data.is_active == true then
            return true, tonumber(data.remaining or 0) or 0
        end
    end

    -- Fallback: raw get_debuffs() scan
    if unit.get_debuffs then
        local ok_raw, debuffs = pcall(function()
            return unit:get_debuffs()
        end)
        if ok_raw and type(debuffs) == "table" then
            local id_set = {}
            for _, id in ipairs(debuff_ids or {}) do
                id_set[id] = true
            end
            for _, debuff in ipairs(debuffs) do
                if debuff and debuff.buff_id and id_set[debuff.buff_id] then
                    local remaining = 0
                    if debuff.expire_time and debuff.duration then
                        local game_time = 0
                        pcall(function() game_time = core.game_time() or 0 end)
                        if game_time > 0 and debuff.expire_time > game_time then
                            remaining = debuff.expire_time - game_time
                        end
                    end
                    return true, remaining
                end
            end
        end
    end

    -- Tertiary fallback: individual debuff_up checks
    if unit.debuff_remains_ms then
        local ok_ms, rem_ms = pcall(function()
            return unit:debuff_remains_ms(debuff_ids)
        end)
        if ok_ms and type(rem_ms) == "number" and rem_ms > 0 then
            return true, rem_ms
        end
    end
    for _, id in ipairs(debuff_ids or {}) do
        local ok_up, up = pcall(function()
            return unit:debuff_up(id)
        end)
        if ok_up and up == true then
            local remaining = 0
            if unit.debuff_remains_ms then
                local ok_ms2, rem_ms2 = pcall(function()
                    return unit:debuff_remains_ms(id)
                end)
                if ok_ms2 and type(rem_ms2) == "number" and rem_ms2 > 0 then
                    remaining = rem_ms2
                end
            end
            return true, remaining
        end
    end

    return false, 0
end

---@param player game_object
---@return integer[]|nil
local function current_seal_judgement_debuff_ids(player)
    if has_any_buff(player, spells.SEAL_OF_WISDOM_IDS) then
        return spells.JOW_DEBUFF_IDS
    end
    if has_any_buff(player, spells.SEAL_OF_THE_CRUSADER_IDS) then
        return spells.JOTC_DEBUFF_IDS
    end
    if has_any_buff(player, spells.SEAL_OF_LIGHT_IDS) then
        return spells.JOL_DEBUFF_IDS
    end
    return nil
end

---@param target game_object|nil
---@param debuff_ids integer[]|nil
---@param menu table|nil
---@return boolean
local function judgement_debuff_needs_refresh(target, debuff_ids, menu)
    if not (target and debuff_ids) then
        return true
    end
    local refresh_under = num_opt(menu, "judgement_refresh_under_sec", 0)
    local active, remaining_ms = get_any_debuff_status(target, debuff_ids)
    if not active then
        return true
    end
    local remaining_sec = remaining_ms / 1000.0
    if refresh_under > 0 and remaining_sec > 0 and remaining_sec <= refresh_under then
        return true
    end
    return false
end

---@param player game_object
---@param range_y number
---@param include_out_of_combat boolean|nil
---@return table<game_object>, integer
local function get_enemies_around(player, range_y, include_out_of_combat)
    local pos = player and player.get_position and player:get_position() or nil
    if not pos then
        return {}, 0
    end
    local include_ooc = include_out_of_combat == true
    local ok, enemies = pcall(function()
        return performance:get_enemy_list_around(unit_helper, pos, range_y, include_ooc, false)
    end)
    if not ok or type(enemies) ~= "table" then
        return {}, 0
    end
    return enemies, #enemies
end

---@param unit game_object|nil
---@param range_y number
---@param include_out_of_combat boolean|nil
---@return table<game_object>, integer
local function get_enemies_around_unit(unit, range_y, include_out_of_combat)
    local pos = unit and unit.get_position and unit:get_position() or nil
    if not pos then
        return {}, 0
    end
    local include_ooc = include_out_of_combat == true
    local ok, enemies = pcall(function()
        return performance:get_enemy_list_around(unit_helper, pos, range_y, include_ooc, false)
    end)
    if not ok or type(enemies) ~= "table" then
        return {}, 0
    end
    return enemies, #enemies
end

---@param enemies table<game_object>
---@return number
local function avg_enemy_hp_pct(enemies)
    if not enemies or #enemies == 0 then
        return 0
    end
    local sum = 0
    local count = 0
    for _, e in __object_safety.live_ipairs(enemies) do
        if e and e:is_alive() and e.get_health_percentage then
            sum = sum + (e:get_health_percentage() or 0)
            count = count + 1
        end
    end
    if count == 0 then
        return 0
    end
    return sum / count
end

---@param player game_object
---@return table<game_object>
local function get_group_members(player)
    local ok, party_range = pcall(function()
        return performance:get_unit_list(player, "get_party_members_in_range", 40, true)
    end)
    if ok and party_range and #party_range > 0 then
        return party_range
    end

    local ok_party, party = pcall(function()
        return performance:get_unit_list(player, "get_party_members")
    end)
    if ok_party and party and #party > 0 then
        return party
    end

    return { player }
end

---@param a game_object|nil
---@param b game_object|nil
---@return boolean
local function same_unit(a, b)
    if not a or not b then
        return false
    end
    local ok_a, ga = pcall(function()
        return a:get_guid()
    end)
    local ok_b, gb = pcall(function()
        return b:get_guid()
    end)
    if ok_a and ok_b and ga and gb then
        return ga == gb
    end
    return __object_safety.same(a,b)
end

---@param player game_object
---@return game_object
local function find_tank(player)
    local group = get_group_members(player)

    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() and ally.get_group_role then
            local ok, role = pcall(function()
                return ally:get_group_role()
            end)
            if ok and role == enums.group_role.TANK then
                return ally
            end
        end
    end

    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() and ally:get_class() == enums.class_id.WARRIOR then
            return ally
        end
    end

    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() and ally:get_class() == enums.class_id.PALADIN then
            return ally
        end
    end

    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() and ally:get_class() == enums.class_id.DRUID then
            return ally
        end
    end

    return player
end

---@param player game_object
---@return game_object|nil
local function find_lowest_hp_ally(player)
    local group = get_group_members(player)
    local lowest = nil
    local lowest_hp = 101

    for _, ally in __object_safety.live_ipairs(group) do
        if ally and ally:is_alive() then
            local hp = ally:get_health_percentage() or 100
            if hp < lowest_hp then
                lowest_hp = hp
                lowest = ally
            end
        end
    end

    local self_hp = player:get_health_percentage() or 100
    if self_hp < lowest_hp then
        return player, self_hp
    end

    return lowest, lowest_hp
end

---@param player game_object
---@param enemies table<game_object>
---@return boolean
local function is_player_targeted(player, enemies)
    if not player or not enemies then
        return false
    end
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy.get_target then
            local ok, t = pcall(function()
                return enemy:get_target()
            end)
            if ok and t and same_unit(t, player) then
                return true
            end
        end
    end
    return false
end

---@param player game_object|nil
---@param enemies table<game_object>|nil
---@return integer
local function count_enemies_targeting_player(player, enemies)
    if not player or not enemies then
        return 0
    end

    local count = 0
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy.get_target then
            local ok, t = pcall(function()
                return enemy:get_target()
            end)
            if ok and t and same_unit(t, player) then
                count = count + 1
            end
        end
    end

    return count
end

---@param player game_object|nil
---@param enemies table<game_object>|nil
---@param melee_range number
---@return integer
local function count_melee_enemies_targeting_player(player, enemies, melee_range)
    if not player or not enemies then
        return 0
    end

    local count = 0
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy.get_target and enemy.distance then
            local ok_t, t = pcall(function()
                return enemy:get_target()
            end)
            if ok_t and t and same_unit(t, player) then
                local ok_d, d = pcall(function()
                    return enemy:distance()
                end)
                if ok_d and type(d) == "number" and d <= melee_range then
                    count = count + 1
                end
            end
        end
    end

    return count
end

---@param unit game_object|nil
---@param enemies table<game_object>|nil
---@param melee_range number
---@return integer
local function count_melee_enemies_targeting_unit(unit, enemies, melee_range)
    if not unit or not enemies then
        return 0
    end

    local count = 0
    for _, enemy in __object_safety.live_ipairs(enemies) do
        if enemy and enemy.get_target and enemy.distance then
            local ok_t, t = pcall(function()
                return enemy:get_target()
            end)
            if ok_t and t and same_unit(t, unit) then
                local ok_d, d = pcall(function()
                    return enemy:distance()
                end)
                if ok_d and type(d) == "number" and d <= melee_range then
                    count = count + 1
                end
            end
        end
    end

    return count
end

---@param menu table
---@return boolean
local function safe_mode_enabled(menu, state)
    return bool_opt(menu, state, "safe_mode", true)
end

---@param menu table
---@return boolean
local function mana_save_enabled(menu, state)
    return bool_opt(menu, state, "mana_save", false)
end

---@param menu table
---@return string
local function aoe_mode_value(menu)
    local idx = menu.aoe_mode and menu.aoe_mode:get() or 1
    if idx == 2 then
        return "single"
    end
    if idx == 3 then
        return "aoe"
    end
    return "auto"
end

---@param enemies_10 integer
---@param menu table
---@return boolean
local function compute_want_aoe(enemies_10, menu, state)
    local mode = (state and state.aoe_mode) or aoe_mode_value(menu)
    if mode == "aoe" then
        return true
    end
    if mode == "single" then
        return false
    end
    local user_min = num_opt(menu, "consecration_min_enemies", 0)
    local aoe_min_default = mana_save_enabled(menu, state) and spells.DEFAULTS.AOE_MIN_SAVE or spells.DEFAULTS.AOE_MIN
    local aoe_min = user_min > 0 and user_min or aoe_min_default
    return enemies_10 >= aoe_min
end

---@param unit game_object
---@return boolean, boolean, boolean
local function scan_dispellable_debuff_types(unit)
    if not unit or not unit:is_alive() then
        return false, false, false
    end

    local has_poison = false
    local has_disease = false
    local has_magic = false

    if unit.get_all_auras then
        local ok_a, auras = pcall(function()
            return unit:get_all_auras()
        end)
        if ok_a and type(auras) == "table" then
            for _, aura in ipairs(auras) do
                local is_debuff = aura
                    and (
                        aura.is_debuff == true
                        or aura.isDebuff == true
                        or aura.debuff == true
                        or aura.is_buff == false
                        or aura.isBuff == false
                    )
                local aura_type = aura and (aura.type or aura.debuff_type or aura.aura_type)
                if is_debuff and aura_type then
                    if aura_type == enums.buff_type.POISON then
                        has_poison = true
                    elseif aura_type == enums.buff_type.DISEASE then
                        has_disease = true
                    elseif aura_type == enums.buff_type.MAGIC then
                        has_magic = true
                    end
                end
            end
        end
    end

    if not unit.get_debuffs then
        return has_poison, has_disease, has_magic
    end
    local ok, debuffs = pcall(function()
        return unit:get_debuffs()
    end)
    if not ok or type(debuffs) ~= "table" then
        return has_poison, has_disease, has_magic
    end
    for _, debuff in ipairs(debuffs) do
        if debuff and debuff.type then
            if debuff.type == enums.buff_type.POISON then
                has_poison = true
            elseif debuff.type == enums.buff_type.DISEASE then
                has_disease = true
            elseif debuff.type == enums.buff_type.MAGIC then
                has_magic = true
            end
        end
    end
    return has_poison, has_disease, has_magic
end

---@param unit game_object
---@return spell|nil
local function dispel_spell_for_unit(unit)
    local has_poison, has_disease, has_magic = scan_dispellable_debuff_types(unit)

    -- Level 42+: Cleanse can remove 1x Magic + 1x Poison + 1x Disease.
    if spells.cleanse and spells.cleanse.is_learned and spells.cleanse:is_learned() then
        if has_magic or has_poison or has_disease then
            return spells.cleanse
        end
        return nil
    end

    -- Pre-42: Purify can remove 1x Poison OR 1x Disease (no Magic).
    if spells.purify and spells.purify.is_learned and spells.purify:is_learned() then
        if has_poison or has_disease then
            return spells.purify
        end
        return nil
    end

    return nil
end

---@param menu table
---@return integer, integer, integer, integer, integer
local function thresholds(menu)
    local safe = safe_mode_enabled(menu, nil)
    local save = mana_save_enabled(menu, nil)
    local hp_panic = safe and spells.DEFAULTS.HP_PANIC_SAFE or spells.DEFAULTS.HP_PANIC
    local hp_emergency = safe and spells.DEFAULTS.HP_EMERGENCY_SAFE or spells.DEFAULTS.HP_EMERGENCY
    local hp_warning = safe and spells.DEFAULTS.HP_WARNING_SAFE or spells.DEFAULTS.HP_WARNING
    local mana_low = save and spells.DEFAULTS.MANA_LOW_SAVE or spells.DEFAULTS.MANA_LOW
    local mana_very_low = save and spells.DEFAULTS.MANA_VERY_LOW_SAVE or spells.DEFAULTS.MANA_VERY_LOW
    return hp_panic, hp_emergency, hp_warning, mana_low, mana_very_low
end

---@param player game_object
---@param menu table
---@return string
local function resolve_role(player, menu, state)
    if bool_opt(menu, state, "tank_mode", false) then
        return "tank"
    end
    if bool_opt(menu, state, "heal_mode", false) then
        return "heal"
    end
    return "dps"
end

---@param player game_object
---@param menu table
---@param enemies table<game_object>
---@return boolean
local function try_global_safety(player, menu, enemies, state)
    local now = now_ms()
    local hp = player:get_health_percentage() or 100
    local mana = player:mana_pct() or 100
    local targeted = is_player_targeted(player, enemies)
    local targeters = count_enemies_targeting_player(player, enemies)
    local melee_targeters = count_melee_enemies_targeting_player(player, enemies, 6.0)
    local forbearance = has_any_debuff(player, spells.FORBEARANCE_DEBUFF_IDS)

    if menu.use_hp_potions and menu.use_hp_potions:get_state() then
        if hp <= menu.hp_potion_at:get() then
            if izi.use_best_health_potion_safe() then
                return true
            end
        end
    end

    local loh_hp = num_opt(menu, "lay_on_hands_at_hp", spells.DEFAULTS.HP_PANIC)
    if bool_opt(menu, state, "use_lay_on_hands", true) and spells.lay_on_hands:is_learned() and spells.lay_on_hands:cooldown_up() then
        if hp <= loh_hp then
            if spells.lay_on_hands:is_castable({ skip_facing = true }) then
                if spells.lay_on_hands:cast(player) then
                    return true
                end
            end
        end
    end

    local bubble_hp = num_opt(menu, "divine_shield_at_hp", spells.DEFAULTS.HP_EMERGENCY)
    if bool_opt(menu, state, "use_divine_shield", true) and spells.divine_shield:is_learned() and spells.divine_shield:cooldown_up() then
        if not forbearance and hp <= bubble_hp and (targeted or #enemies >= 2) then
            if spells.divine_shield:is_castable({ skip_facing = true }) then
                if spells.divine_shield:cast(player) then
                    return true
                end
            end
        end
    end

    local dp_hp = num_opt(menu, "divine_protection_at_hp", spells.DEFAULTS.HP_EMERGENCY)
    if bool_opt(menu, state, "use_divine_protection", true) and spells.divine_protection:is_learned() and spells.divine_protection:cooldown_up() then
        if not forbearance and hp <= dp_hp and (not spells.divine_shield:is_learned() or not spells.divine_shield:cooldown_up()) then
            if spells.divine_protection:is_castable({ skip_facing = true }) then
                if spells.divine_protection:cast(player) then
                    return true
                end
            end
        end
    end

    local bop_hp = num_opt(menu, "blessing_of_protection_at_hp", spells.DEFAULTS.HP_EMERGENCY)
    if bool_opt(menu, state, "use_blessing_of_protection", true) and spells.blessing_of_protection:is_learned() and spells.blessing_of_protection:cooldown_up() then
        local min_melee = num_opt(menu, "bop_min_melee_targeters", 1)
        if not forbearance
            and hp <= bop_hp
            and (min_melee <= 0 or melee_targeters >= min_melee) then
            if spells.blessing_of_protection:is_castable({ skip_facing = true }) then
                if spells.blessing_of_protection:cast(player) then
                    return true
                end
            end
        end
    end

    if spells.blessing_of_freedom:is_learned() then
        local rooted = false
        local slowed = false
        local slow_threshold = math.max(0.10, math.min(0.90, num_opt(menu, "freedom_slow_pct", 30) / 100))
        pcall(function()
            rooted = (player:is_rooted() == true)
        end)
        pcall(function()
            slowed = (select(1, player:is_slowed(slow_threshold)) == true)
        end)
        if rooted or slowed then
            if spells.blessing_of_freedom:is_castable({ skip_facing = true }) then
                if spells.blessing_of_freedom:cast(player) then
                    return true
                end
            end
        end
    end

    local self_hl_hp = num_opt(menu, "self_holy_light_at_hp", spells.DEFAULTS.HP_EMERGENCY)
    local hl_skip_targeters = num_opt(menu, "self_holy_light_max_targeters", 0)
    if bool_opt(menu, state, "use_self_holy_light", true)
        and spells.holy_light:is_learned()
        and mana >= 18
        and hp <= self_hl_hp
        and (hl_skip_targeters <= 0 or targeters < hl_skip_targeters) then
        if spells.holy_light:is_castable({ skip_facing = true }) then
            if spells.holy_light:cast(player) then
                return true
            end
        end
    end

    local self_fol_hp = num_opt(menu, "self_flash_of_light_at_hp", spells.DEFAULTS.HP_WARNING)
    local fol_skip_targeters = num_opt(menu, "self_flash_of_light_max_targeters", 1)
    if bool_opt(menu, state, "use_self_flash_of_light", true)
        and spells.flash_of_light:is_learned()
        and mana >= 10
        and hp <= self_fol_hp
        and (fol_skip_targeters <= 0 or targeters < fol_skip_targeters) then
        if spells.flash_of_light:is_castable({ skip_facing = true }) then
            if spells.flash_of_light:cast(player) then
                return true
            end
        end
    end

    if bool_opt(menu, state, "dispel", true) then
        local dispel_min_mana = num_opt(menu, "min_mana_for_dispel", 6)
        local dispel_spell = (mana >= dispel_min_mana) and dispel_spell_for_unit(player) or nil
        if dispel_spell then
            if not cleanse_throttle_ready(player, now) then
                return false
            end
            if dispel_spell:is_castable({ skip_facing = true }) then
                if dispel_spell:cast(player) then
                    mark_cleanse_cast(player, now)
                    return true
                end
            end
        end
    end

    return false
end

---@param player game_object
---@param menu table
---@param role string
---@return boolean
local function try_maintain_buffs(player, menu, role, state)
    local now = now_ms()
    if now - last_buff_check_ms < BUFF_CHECK_INTERVAL_MS then
        return false
    end
    last_buff_check_ms = now

    if player:is_channeling_or_casting() then
        return false
    end

    if bool_opt(menu, state, "auto_auras", true) then
        local want_aura = nil
        if role == "tank" then
            want_aura = "devotion"
        elseif role == "heal" then
            want_aura = "concentration"
        else
            want_aura = safe_mode_enabled(menu, state) and "devotion" or "retribution"
        end

        if want_aura == "devotion" and spells.devotion_aura:is_learned() and not has_any_buff(player, spells.AURA_DEVOTION_IDS) then
            if spells.devotion_aura:is_castable({ skip_facing = true }) then
                if spells.devotion_aura:cast(player) then
                    return true
                end
            end
        elseif want_aura == "concentration" and spells.concentration_aura:is_learned() and not has_any_buff(player, spells.AURA_CONCENTRATION_IDS) then
            if spells.concentration_aura:is_castable({ skip_facing = true }) then
                if spells.concentration_aura:cast(player) then
                    return true
                end
            end
        elseif want_aura == "retribution" and spells.retribution_aura:is_learned() and not has_any_buff(player, spells.AURA_RETRIBUTION_IDS) then
            if spells.retribution_aura:is_castable({ skip_facing = true }) then
                if spells.retribution_aura:cast(player) then
                    return true
                end
            end
        end
    end

    if role == "tank" and spells.righteous_fury:is_learned() and not has_any_buff(player, spells.RIGHTEOUS_FURY_IDS) then
        if spells.righteous_fury:is_castable({ skip_facing = true }) then
            if spells.righteous_fury:cast(player) then
                return true
            end
        end
    end

    if not bool_opt(menu, state, "auto_blessings", true) then
        return false
    end

    -- =========================================================================
    -- BLESSINGS: exactly-one selection (avoid overwrite thrashing)
    -- =========================================================================

    local blessing_catalog = {
        { key = "sanctuary", spell = spells.blessing_of_sanctuary, ids = spells.BLESSING_SANCTUARY_IDS },
        { key = "kings", spell = spells.blessing_of_kings, ids = spells.BLESSING_KINGS_IDS },
        { key = "wisdom", spell = spells.blessing_of_wisdom, ids = spells.BLESSING_WISDOM_IDS },
        { key = "might", spell = spells.blessing_of_might, ids = spells.BLESSING_MIGHT_IDS },
        { key = "salvation", spell = spells.blessing_of_salvation, ids = spells.BLESSING_SALVATION_IDS },
        { key = "light", spell = spells.blessing_of_light, ids = spells.BLESSING_LIGHT_IDS }
    }

    local function get_active_blessing_key(unit)
        for _, entry in ipairs(blessing_catalog) do
            if entry.ids and has_any_buff(unit, entry.ids) then
                return entry.key
            end
        end
        return nil
    end

    local function has_any_known_blessing(unit)
        return get_active_blessing_key(unit) ~= nil
    end

    local mana = player:mana_pct() or 100
    local want_wisdom = role == "heal" or mana_save_enabled(menu, state) or mana <= 35

    local desired_self_key = nil
    if role == "tank" then
        if spells.blessing_of_sanctuary:is_learned() then
            desired_self_key = "sanctuary"
        elseif spells.blessing_of_kings:is_learned() then
            desired_self_key = "kings"
        else
            desired_self_key = want_wisdom and "wisdom" or "might"
        end
    elseif role == "heal" then
        desired_self_key = "wisdom"
    else
        desired_self_key = want_wisdom and "wisdom" or "might"
    end

    local desired_self = nil
    for _, entry in ipairs(blessing_catalog) do
        if entry.key == desired_self_key then
            desired_self = entry
            break
        end
    end

    if desired_self and desired_self.spell and desired_self.spell:is_learned() then
        local active_key = get_active_blessing_key(player)
        local already_ok = desired_self.ids and has_any_buff(player, desired_self.ids)
        local allow_overwrite = bool_opt(menu, state, "self_overwrite_blessings", true)

        if not already_ok and (not active_key or allow_overwrite) then
            if desired_self.spell:is_castable({ skip_facing = true }) then
                if desired_self.spell:cast(player) then
                    return true
                end
            end
        end
    end

    -- Party Blessings (minimal heuristic, optional)
    if bool_opt(menu, state, "enable_party_blessings", false) then
        local ok_party, in_party = pcall(function()
            return player:is_in_party()
        end)
        if ok_party and in_party then
            local group = get_group_members(player)
            local tank = find_tank(player)

            local function unit_role(u)
                if not u or not u.get_group_role then
                    return nil
                end
                local ok, r = pcall(function()
                    return u:get_group_role()
                end)
                if ok and type(r) == "number" then
                    return r
                end
                return nil
            end

            local allow_overwrite_party = bool_opt(menu, state, "party_overwrite_blessings", false)
            local use_salv = bool_opt(menu, state, "party_use_salvation", true) and spells.blessing_of_salvation:is_learned()
            local use_light_on_tank = bool_opt(menu, state, "party_use_light_on_tank", true) and spells.blessing_of_light:is_learned()

            for _, ally in __object_safety.live_ipairs(group) do
                if ally and ally:is_alive() and not same_unit(ally, player) then
                    local existing = has_any_known_blessing(ally)
                    if (not existing) or allow_overwrite_party then
                        local desired = nil
                        local r = unit_role(ally)

                        if tank and same_unit(ally, tank) then
                            if use_light_on_tank then
                                desired = spells.blessing_of_light
                            elseif spells.blessing_of_kings:is_learned() then
                                desired = spells.blessing_of_kings
                            elseif spells.blessing_of_sanctuary:is_learned() then
                                desired = spells.blessing_of_sanctuary
                            elseif spells.blessing_of_might:is_learned() then
                                desired = spells.blessing_of_might
                            end
                        elseif r == enums.group_role.HEALER then
                            if spells.blessing_of_wisdom:is_learned() then
                                desired = spells.blessing_of_wisdom
                            end
                        else
                            if use_salv then
                                desired = spells.blessing_of_salvation
                            elseif spells.blessing_of_might:is_learned() then
                                desired = spells.blessing_of_might
                            end
                        end

                        if desired and desired:is_learned() then
                            if desired == spells.blessing_of_might and has_any_buff(ally, spells.BLESSING_MIGHT_IDS) then
                                desired = nil
                            elseif desired == spells.blessing_of_wisdom and has_any_buff(ally, spells.BLESSING_WISDOM_IDS) then
                                desired = nil
                            elseif desired == spells.blessing_of_kings and has_any_buff(ally, spells.BLESSING_KINGS_IDS) then
                                desired = nil
                            elseif desired == spells.blessing_of_sanctuary and has_any_buff(ally, spells.BLESSING_SANCTUARY_IDS) then
                                desired = nil
                            elseif desired == spells.blessing_of_salvation and has_any_buff(ally, spells.BLESSING_SALVATION_IDS) then
                                desired = nil
                            elseif desired == spells.blessing_of_light and has_any_buff(ally, spells.BLESSING_LIGHT_IDS) then
                                desired = nil
                            end

                            if desired and desired:is_castable({ skip_facing = true }) then
                                if desired:cast(ally) then
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

---@param player game_object
---@param menu table
---@param role string
---@param target game_object|nil
---@param enemies_pvp table<game_object>|nil
---@return boolean
local function try_pvp_overlay(player, menu, role, target, enemies_pvp, state)
    if not bool_opt(menu, state, "pvp_mode", false) then
        return false
    end

    local forbearance = has_any_debuff(player, spells.FORBEARANCE_DEBUFF_IDS)

    local pvp_target = nil
    if target and target:is_alive() and target.is_player and target:is_player() then
        pvp_target = target
    else
        for _, enemy in __object_safety.live_ipairs(enemies_pvp or {}) do
            if enemy and enemy:is_alive() and enemy.is_player and enemy:is_player() then
                local ok_t, t = pcall(function()
                    return enemy:get_target()
                end)
                if ok_t and t and same_unit(t, player) then
                    pvp_target = enemy
                    break
                end
                if not pvp_target then
                    pvp_target = enemy
                end
            end
        end
    end

    if not pvp_target then
        return false
    end

    local now = now_ms()
    local manual_choice = manual_seal_choice(state, now)
    if manual_choice then
        if try_maintain_manual_seal(player, manual_choice, now) then
            return true
        end
    else
        if seal_throttle_ready(now) and spells.seal_of_justice:is_learned() and role ~= "tank" and not has_any_buff(player, spells.SEAL_OF_JUSTICE_IDS) then
            if spells.seal_of_justice:is_castable({ skip_facing = true }) then
                if spells.seal_of_justice:cast(player) then
                    last_seal_cast_ms = now
                    return true
                end
            end
        end
    end

    local hp = player:get_health_percentage() or 100
    if spells.divine_shield:is_learned() and spells.divine_shield:cooldown_up() then
        local pvp_bubble = safe_mode_enabled(menu, state) and 30 or 22
        if not forbearance and hp <= pvp_bubble then
            if spells.divine_shield:is_castable({ skip_facing = true }) then
                if spells.divine_shield:cast(player) then
                    return true
                end
            end
        end
    end

    if spells.hammer_of_justice:is_learned() and spells.hammer_of_justice:cooldown_up() then
        if pvp_target:distance() <= 6.0 then
            if spells.hammer_of_justice:is_castable() then
                if spells.hammer_of_justice:cast(pvp_target) then
                    return true
                end
            end
        end
    end

    local allow_judge = true
    local debuff_ids = current_seal_judgement_debuff_ids(player)
    if bool_opt(menu, state, "judgement_only_if_missing", true) then
        if debuff_ids and not judgement_debuff_needs_refresh(pvp_target, debuff_ids, menu) then
            allow_judge = false
        end
    end

    if allow_judge and bool_opt(menu, state, "judgement_skip_if_other_active", false) and target_has_other_judgement_active(pvp_target, debuff_ids) then
        allow_judge = false
    end

    if allow_judge and spells.judgement:is_learned() and spells.judgement:cooldown_up() then
        if spells.judgement:is_castable() then
            if spells.judgement:cast(pvp_target) then
                return true
            end
        end
    end

    return false
end

---@param player game_object
---@param menu table
---@param tick_tracker resource_ticks_tracker|nil
---@return boolean
local function try_heal_mode(player, menu, tick_tracker, state)
    local now = now_ms()
    if now - last_heal_cast_ms < HEAL_THROTTLE_MS then
        return false
    end

    local mana = player:mana_pct() or 100
    local safe = safe_mode_enabled(menu, state)
    local save = mana_save_enabled(menu, state)
    local _, _, _, _, mana_very_low = thresholds(menu)

    local tank = find_tank(player)
    local tank_hp = (tank and tank:get_health_percentage()) or 100

    local lowest_ally, lowest_hp = find_lowest_hp_ally(player)

    if spells.lay_on_hands:is_learned() and spells.lay_on_hands:cooldown_up() then
        if tank and tank_hp <= 10 then
            if spells.lay_on_hands:is_castable({ skip_facing = true }) then
                if spells.lay_on_hands:cast(tank) then
                    last_heal_cast_ms = now
                    return true
                end
            end
        end
    end

    if spells.divine_favor:is_learned() and spells.divine_favor:cooldown_up() then
        if tank and tank_hp <= (safe and 35 or 25) then
            if spells.divine_favor:is_castable({ skip_facing = true }) then
                if spells.divine_favor:cast(player) then
                    last_heal_cast_ms = now
                    return true
                end
            end
        end
    end

    if bool_opt(menu, state, "dispel", true) then
        local dispel_min_mana = num_opt(menu, "min_mana_for_dispel", 6)
        local dispel_spell = (mana >= dispel_min_mana and lowest_ally) and dispel_spell_for_unit(lowest_ally) or nil
        if dispel_spell and cleanse_throttle_ready(lowest_ally, now) then
            local use_whitelist = bool_opt(menu, state, "dispel_use_whitelist", false)
            if not use_whitelist or dispel_whitelist.is_unit_whitelisted(menu, lowest_ally) then
                if dispel_spell:is_castable({ skip_facing = true }) then
                    if dispel_spell:cast(lowest_ally) then
                        mark_cleanse_cast(lowest_ally, now)
                        last_heal_cast_ms = now
                        return true
                    end
                end
            end
        end
    end

    if spells.blessing_of_protection:is_learned() and spells.blessing_of_protection:cooldown_up() then
        local bop_hp = num_opt(menu, "blessing_of_protection_at_hp", 35)
        local ally_forbearance = lowest_ally and has_any_debuff(lowest_ally, spells.FORBEARANCE_DEBUFF_IDS)
        local ally_min_melee = num_opt(menu, "ally_bop_min_melee_targeters", 1)
        local allow_by_pressure = true
        if lowest_ally and ally_min_melee > 0 then
            local enemies_near_ally, _ = get_enemies_around_unit(lowest_ally, 10.0, false)
            local melee_targeters = count_melee_enemies_targeting_unit(lowest_ally, enemies_near_ally, 6.0)
            allow_by_pressure = melee_targeters >= ally_min_melee
        end

        if lowest_ally and not ally_forbearance and lowest_hp <= bop_hp and safe and allow_by_pressure then
            if spells.blessing_of_protection:is_castable({ skip_facing = true }) then
                if spells.blessing_of_protection:cast(lowest_ally) then
                    last_heal_cast_ms = now
                    return true
                end
            end
        end
    end

    if spells.holy_light:is_learned() and not player:is_moving() and mana >= 18 then
        local threshold = num_opt(menu, "tank_holy_light_at_hp", (save and 25 or (safe and 45 or 35)))
        if tank and tank_hp <= threshold then
            if spells.holy_light:is_castable({ skip_facing = true }) then
                if spells.holy_light:cast(tank) then
                    last_heal_cast_ms = now
                    return true
                end
            end
        end
    end

    if spells.flash_of_light:is_learned() and mana >= 8 then
        local fol_hp = num_opt(menu, "tank_flash_of_light_at_hp", 80)
        if tank and tank_hp <= fol_hp and not save then
            if spells.flash_of_light:is_castable({ skip_facing = true }) then
                if spells.flash_of_light:cast(tank) then
                    last_heal_cast_ms = now
                    return true
                end
            end
        end
    end

    local allow_r1 = bool_opt(menu, state, "enable_fol_rank1", true)
    local r1_low = num_opt(menu, "fol_rank1_window_low", 70)
    local r1_high = num_opt(menu, "fol_rank1_window_high", 90)

    if save and allow_r1 and spells.flash_of_light_r1:is_learned() and mana >= 5 then
        local group_stable = (tank_hp >= 85) and (lowest_hp >= 80)
        if tank and tank_hp >= r1_low and tank_hp <= r1_high and group_stable then
            if spells.flash_of_light_r1:is_castable({ skip_facing = true }) then
                if spells.flash_of_light_r1:cast(tank) then
                    last_heal_cast_ms = now
                    return true
                end
            end
        end
    end

    local ally_fol_hp = num_opt(menu, "ally_flash_of_light_at_hp", 60)
    if spells.flash_of_light:is_learned() and mana >= 8 and lowest_ally and lowest_hp <= ally_fol_hp then
        if spells.flash_of_light:is_castable({ skip_facing = true }) then
            if spells.flash_of_light:cast(lowest_ally) then
                last_heal_cast_ms = now
                return true
            end
        end
    end

    if spells.holy_shock:is_learned() and spells.holy_shock:cooldown_up() and mana >= 12 then
        local hs_hp = num_opt(menu, "holy_shock_at_hp", (safe and 30 or 25))
        if (player:is_moving() and lowest_ally and lowest_hp <= ally_fol_hp) or (lowest_ally and lowest_hp <= hs_hp) then
            if spells.holy_shock:is_castable({ skip_facing = true }) then
                if spells.holy_shock:cast(lowest_ally or player) then
                    last_heal_cast_ms = now
                    return true
                end
            end
        end
    end

    if save and tick_tracker and tick_tracker.fsr_remaining_ms then
        local fsr_rem = tick_tracker:fsr_remaining_ms()
        local urgent = (tank_hp <= (safe and 55 or 45)) or (lowest_hp <= (safe and 55 or 45))
        if not urgent and fsr_rem > 0 and (tank_hp >= 85) then
            return false
        end
    end

    if bool_opt(menu, state, "allow_melee_for_healer", false) then
        local target = izi.target()
        if target and target:is_valid_enemy() and target:is_alive() and player:can_attack(target) then
            local ttd = 0
            pcall(function()
                ttd = target:time_to_die() or 0
            end)

            local manual_choice = manual_seal_choice(state, now)
            if manual_choice then
                if try_maintain_manual_seal(player, manual_choice, now) then
                    return true
                end
            else
                if seal_throttle_ready(now) and mana <= 70 and spells.seal_of_wisdom:is_learned() and not has_any_buff(player, spells.SEAL_OF_WISDOM_IDS) then
                    if spells.seal_of_wisdom:is_castable({ skip_facing = true }) then
                        if spells.seal_of_wisdom:cast(player) then
                            last_seal_cast_ms = now
                            enter_seal_regen_mode(now)
                            return true
                        end
                    end
                end
            end

            local jotw_missing = true
            if ttd >= 6 and buff_manager and buff_manager.get_debuff_data then
                local deb = buff_manager:get_debuff_data(target, spells.JOW_DEBUFF_IDS)
                jotw_missing = not (deb and deb.is_active)
            end

            if spells.judgement:is_learned() and spells.judgement:cooldown_up() and jotw_missing and mana <= 60 then
                if spells.judgement:is_castable() then
                    if spells.judgement:cast(target) then
                        return true
                    end
                end
            end

            auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
        end
    end

    if mana <= mana_very_low then
        return false
    end

    last_heal_cast_ms = now
    return false
end

---@param player game_object
---@param menu table
---@param enemies_10 integer
---@param want_aoe boolean
---@param target game_object|nil
---@return boolean
local function try_tank_mode(player, menu, enemies_10, want_aoe, target, state)
    local mana = player:mana_pct() or 100
    local safe = safe_mode_enabled(menu, state)
    local _, hp_emergency, _, _, mana_very_low = thresholds(menu)
    local now = now_ms()

    local ttd = 0
    if target and target.time_to_die then
        pcall(function()
            ttd = target:time_to_die() or 0
        end)
    end

    if seal_throttle_ready(now) then
        local manual_choice = manual_seal_choice(state, now)
        if manual_choice then
            if try_maintain_manual_seal(player, manual_choice, now) then
                return true
            end
        else
        local wisdom_up = has_any_buff(player, spells.SEAL_OF_WISDOM_IDS)
        if seal_regen_active(now, mana, mana_very_low, wisdom_up) and spells.seal_of_wisdom:is_learned() then
            if not wisdom_up and mana <= mana_very_low and ttd >= 12 then
                if spells.seal_of_wisdom:is_castable({ skip_facing = true }) then
                    if spells.seal_of_wisdom:cast(player) then
                        last_seal_cast_ms = now
                        enter_seal_regen_mode(now)
                        return true
                    end
                end
            end
        else
            if spells.seal_of_wisdom:is_learned() and mana <= mana_very_low and ttd >= 12 and not wisdom_up then
                if spells.seal_of_wisdom:is_castable({ skip_facing = true }) then
                    if spells.seal_of_wisdom:cast(player) then
                        last_seal_cast_ms = now
                        enter_seal_regen_mode(now)
                        return true
                    end
                end
            end

            if spells.seal_of_righteousness:is_learned()
                and (mana > mana_very_low or not spells.seal_of_wisdom:is_learned())
                and not has_any_buff(player, spells.SEAL_OF_RIGHTEOUSNESS_IDS) then
                if spells.seal_of_righteousness:is_castable({ skip_facing = true }) then
                    if spells.seal_of_righteousness:cast(player) then
                        last_seal_cast_ms = now
                        return true
                    end
                end
            end
        end
        end
    end

    if not target or not target:is_valid_enemy() or not target:is_alive() or not player:can_attack(target) then
        return false
    end

    local thp = target:get_health_percentage() or 100
    if spells.hammer_of_wrath and spells.hammer_of_wrath:is_learned() then
        if bool_opt(menu, nil, "paladin_detailed_log_enabled", false) then
            log_throttled(menu, "tank_how_context", 2000,
                string.format("HoW context: thp=%.0f%%, mana=%.0f%%, cd_up=%s",
                    thp, mana, tostring(spells.hammer_of_wrath:cooldown_up())),
                "Tank")
        end
    end

    if spells.hammer_of_wrath and spells.hammer_of_wrath:is_learned() and spells.hammer_of_wrath:cooldown_up() and thp <= 20 and mana >= 10 then
        if spells.hammer_of_wrath:is_castable() then
            if spells.hammer_of_wrath:cast(target) then
                log_throttled(menu, "tank_how_cast", 1000, "Casting Hammer of Wrath", "Tank")
                return true
            end
        else
            log_throttled(menu, "tank_how_not_castable", 2000, "Hammer of Wrath not castable", "Tank")
        end
    end

    if spells.judgement:is_learned() and spells.judgement:cooldown_up() and mana >= 10 then
        local jm = mana_save_enabled(menu, state)
            and num_opt(menu, "judgement_min_mana_save", 6)
            or num_opt(menu, "judgement_min_mana", 12)
        if mana >= jm then
            local allow_judge = true
            local debuff_ids = current_seal_judgement_debuff_ids(player)
            if bool_opt(menu, state, "judgement_only_if_missing", true) then
                if debuff_ids and not judgement_debuff_needs_refresh(target, debuff_ids, menu) then
                    allow_judge = false
                    log_throttled(menu, "tank_judgement_skip_active", 2500, "Skipping Judgement - Debuff already active", "Tank")
                end
            end
            if allow_judge and bool_opt(menu, state, "judgement_skip_if_other_active", false) and target_has_other_judgement_active(target, debuff_ids) then
                allow_judge = false
            end
            if allow_judge and spells.judgement:is_castable() then
                if spells.judgement:cast(target) then
                    return true
                end
            end
        end
    end

    if spells.holy_shield:is_learned() and spells.holy_shield:cooldown_up() and enemies_10 >= 1 and mana >= 10 then
        if bool_opt(menu, state, "use_holy_shield", true) and mana >= num_opt(menu, "holy_shield_min_mana", 10) then
            if (now - (last_holy_shield_ms or 0)) >= HOLY_SHIELD_RETRY_MS then
                local hs_up = has_any_buff(player, spells.HOLY_SHIELD_IDS)
                local hs_remains_ms = 0
                local hs_stacks = 0
                if hs_up then
                    pcall(function()
                        hs_remains_ms = player:buff_remains_ms(spells.HOLY_SHIELD_IDS) or 0
                    end)
                    pcall(function()
                        hs_stacks = player:get_buff_stacks(spells.HOLY_SHIELD_IDS) or 0
                    end)
                end
                local refresh = (not hs_up)
                    or (hs_remains_ms > 0 and hs_remains_ms <= 1000)
                    or (hs_stacks > 0 and hs_stacks <= 2)
                if refresh then
                    local hs_spell = spells.holy_shield
                    local downrank_enabled = bool_opt(menu, state, "enable_holy_shield_downrank", true)
                    local downrank_threshold = num_opt(menu, "holy_shield_downrank_threshold", 50)

                    if downrank_enabled and mana <= downrank_threshold and spells.holy_shield_r1 and spells.holy_shield_r1.is_learned and spells.holy_shield_r1:is_learned() then
                        hs_spell = spells.holy_shield_r1
                    end

                    if hs_spell and hs_spell:is_castable({ skip_facing = true }) then
                        if hs_spell:cast(player) then
                            last_holy_shield_ms = now
                            return true
                        end
                    end
                end
            end
        end
    end

    local consec_min_enemies = num_opt(menu, "consecration_min_enemies", spells.DEFAULTS.AOE_MIN)
    local allow_consec = bool_opt(menu, state, "use_consecration", true)

    if allow_consec and spells.consecration:is_learned() and want_aoe and enemies_10 >= consec_min_enemies and not player:is_moving() then
        local min_mana = mana_save_enabled(menu, state)
            and num_opt(menu, "consecration_min_mana_save", 18)
            or num_opt(menu, "consecration_min_mana", 35)

        if mana >= min_mana then
            if mana_save_enabled(menu, state) and bool_opt(menu, state, "enable_consecration_downrank", true) and spells.consecration_r1:is_learned() then
                if spells.consecration_r1:is_castable({ skip_facing = true }) then
                    if spells.consecration_r1:cast(player) then
                        return true
                    end
                end
            else
                if spells.consecration:is_castable({ skip_facing = true }) then
                    if spells.consecration:cast(player) then
                        return true
                    end
                end
            end
        end
    end

    if spells.blessing_of_protection:is_learned() and spells.blessing_of_protection:cooldown_up() then
        local hp = player:get_health_percentage() or 100
        local forbearance = has_any_debuff(player, spells.FORBEARANCE_DEBUFF_IDS)
        if safe and not forbearance and hp <= hp_emergency and enemies_10 >= spells.DEFAULTS.AOE_BIG then
            if spells.blessing_of_protection:is_castable({ skip_facing = true }) then
                if spells.blessing_of_protection:cast(player) then
                    return true
                end
            end
        end
    end

    auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
    return false
end

---@param player game_object
---@param menu table
---@param enemies_10 integer
---@param enemies table<game_object>
---@param want_aoe boolean
---@param target game_object|nil
---@return boolean
local function try_dps_mode(player, menu, enemies_10, enemies, want_aoe, target, state)
    local mana = player:mana_pct() or 100
    local safe = safe_mode_enabled(menu, state)
    local save = mana_save_enabled(menu, state)
    local _, _, _, _, mana_very_low = thresholds(menu)
    local now = now_ms()
    local manual_choice = manual_seal_choice(state, now)

    if not target or not target:is_valid_enemy() or not target:is_alive() or not player:can_attack(target) then
        return false
    end

    local swing_speed = 0
    swing_speed = get_swing_speed(player)

    local ttd = 0
    pcall(function()
        ttd = target:time_to_die() or 0
    end)

    local jotc_missing = true
    if buff_manager and buff_manager.get_debuff_data then
        local deb = buff_manager:get_debuff_data(target, spells.JOTC_DEBUFF_IDS)
        jotc_missing = not (deb and deb.is_active)
    end

    local jotc_min_ttd = num_opt(menu, "jotc_min_ttd", 18)
    local pvp_seal_lock = (not manual_choice)
        and bool_opt(menu, state, "pvp_mode", false)
        and spells.seal_of_justice:is_learned()
        and has_any_buff(player, spells.SEAL_OF_JUSTICE_IDS)
    local want_jotc_opener = (not manual_choice)
        and (not pvp_seal_lock)
        and bool_opt(menu, state, "enable_jotc_opener", true)
        and ttd >= jotc_min_ttd
        and not save
        and mana >= 25
        and spells.seal_of_the_crusader:is_learned()
        and jotc_missing

    if want_jotc_opener then
        if seal_throttle_ready(now) and not has_any_buff(player, spells.SEAL_OF_THE_CRUSADER_IDS) then
            if spells.seal_of_the_crusader:is_castable({ skip_facing = true }) then
                if spells.seal_of_the_crusader:cast(player) then
                    last_seal_cast_ms = now
                    return true
                end
            end
        end
        if spells.judgement:is_learned() and spells.judgement:cooldown_up() then
            if spells.judgement:is_castable() then
                if spells.judgement:cast(target) then
                    return true
                end
            end
        end
    end

    if not pvp_seal_lock and not want_jotc_opener then
        if not seal_throttle_ready(now) then
            return false
        end

        if manual_choice then
            if try_maintain_manual_seal(player, manual_choice, now) then
                return true
            end
        else
            local wisdom_up = has_any_buff(player, spells.SEAL_OF_WISDOM_IDS)
            if seal_regen_active(now, mana, mana_very_low, wisdom_up) and spells.seal_of_wisdom:is_learned() then
                if not wisdom_up and mana <= mana_very_low then
                    if spells.seal_of_wisdom:is_castable({ skip_facing = true }) then
                        if spells.seal_of_wisdom:cast(player) then
                            last_seal_cast_ms = now
                            enter_seal_regen_mode(now)
                            return true
                        end
                    end
                end
                return false
            end

        if swing_speed <= 0 then
            if any_seal_up(player) then
                return false
            end
            if spells.seal_of_righteousness:is_learned() and not has_any_buff(player, spells.SEAL_OF_RIGHTEOUSNESS_IDS) then
                if spells.seal_of_righteousness:is_castable({ skip_facing = true }) then
                    if spells.seal_of_righteousness:cast(player) then
                        last_seal_cast_ms = now
                        return true
                    end
                end
            end
            return false
        end

        local want_command = spells.seal_of_command:is_learned() and swing_speed >= 3.5
        if want_command then
            if spells.seal_of_command:is_learned() and not has_any_buff(player, spells.SEAL_OF_COMMAND_IDS) then
                if spells.seal_of_command:is_castable({ skip_facing = true }) then
                    if spells.seal_of_command:cast(player) then
                        last_seal_cast_ms = now
                        return true
                    end
                end
            end
        else
            if spells.seal_of_righteousness:is_learned() and not has_any_buff(player, spells.SEAL_OF_RIGHTEOUSNESS_IDS) then
                if spells.seal_of_righteousness:is_castable({ skip_facing = true }) then
                    if spells.seal_of_righteousness:cast(player) then
                        last_seal_cast_ms = now
                        return true
                    end
                end
            end
        end
        end
    end

    local thp = target:get_health_percentage() or 100
    if spells.hammer_of_wrath:is_learned() and spells.hammer_of_wrath:cooldown_up() and thp <= 20 and mana >= 10 then
        if spells.hammer_of_wrath:is_castable() then
            if spells.hammer_of_wrath:cast(target) then
                return true
            end
        end
    end

    if spells.judgement:is_learned() and spells.judgement:cooldown_up() then
        local need_mana = save and num_opt(menu, "judgement_min_mana_save", 6) or num_opt(menu, "judgement_min_mana", 12)
        if mana >= need_mana then
            local allow_judge = true
            local debuff_ids = current_seal_judgement_debuff_ids(player)
            if bool_opt(menu, state, "judgement_only_if_missing", true) then
                if debuff_ids and not judgement_debuff_needs_refresh(target, debuff_ids, menu) then
                    allow_judge = false
                    log_throttled(menu, "dps_judgement_skip_active", 2500, "Skipping Judgement - Debuff already active", "DPS")
                end
            end
            if allow_judge and bool_opt(menu, state, "judgement_skip_if_other_active", false) and target_has_other_judgement_active(target, debuff_ids) then
                allow_judge = false
            end
            if allow_judge and spells.judgement:is_castable() then
                if spells.judgement:cast(target) then
                    return true
                end
            end
        end
    end

    local consec_min_enemies = num_opt(menu, "consecration_min_enemies", spells.DEFAULTS.AOE_MIN)
    if bool_opt(menu, state, "use_consecration", true) and spells.consecration:is_learned() and want_aoe and enemies_10 >= consec_min_enemies and not player:is_moving() then
        local min_mana = save and num_opt(menu, "consecration_min_mana_save", 18) or num_opt(menu, "consecration_min_mana", 35)
        if mana >= min_mana then
            if save and spells.consecration_r1:is_learned() then
                if spells.consecration_r1:is_castable({ skip_facing = true }) then
                    if spells.consecration_r1:cast(player) then
                        return true
                    end
                end
            else
                if not save then
                    local avg_hp = avg_enemy_hp_pct(enemies)
                    if enemies_10 >= spells.DEFAULTS.AOE_BIG and avg_hp > 0 and avg_hp <= 35 then
                        if spells.consecration:is_castable({ skip_facing = true }) then
                            if spells.consecration:cast(player) then
                                return true
                            end
                        end
                    end
                end

                if spells.consecration:is_castable({ skip_facing = true }) then
                    if spells.consecration:cast(player) then
                        return true
                    end
                end
            end
        end
    end

    if spells.exorcism:is_learned() and spells.exorcism:cooldown_up() and mana >= 12 then
        -- Classic Exorcism is only valid on Undead/Demon targets.
        if is_unit_undead_or_demon(target) and spells.exorcism:is_castable_to_unit(target) then
            if spells.exorcism:is_castable() then
                if spells.exorcism:cast(target) then
                    return true
                end
            end
        end
    end

    if spells.hammer_of_justice:is_learned() and spells.hammer_of_justice:cooldown_up() then
        local should_stun = false
        pcall(function()
            should_stun = target:is_casting() or (safe and enemies_10 >= 2)
        end)
        if should_stun and target:distance() <= 6.0 then
            if spells.hammer_of_justice:is_castable() then
                if spells.hammer_of_justice:cast(target) then
                    return true
                end
            end
        end
    end

    if spells.repentance:is_learned() and spells.repentance:cooldown_up() and safe and enemies_10 >= 2 then
        if spells.repentance:is_castable() then
            if spells.repentance:cast(target) then
                return true
            end
        end
    end

    if not manual_choice or manual_choice == "wisdom" then
        if seal_throttle_ready(now) and spells.seal_of_wisdom:is_learned() and mana <= mana_very_low and not has_any_buff(player, spells.SEAL_OF_WISDOM_IDS) then
            if spells.seal_of_wisdom:is_castable({ skip_facing = true }) then
                if spells.seal_of_wisdom:cast(player) then
                    last_seal_cast_ms = now
                    enter_seal_regen_mode(now)
                    return true
                end
            end
        end

        local jotw_missing = true
        if buff_manager and buff_manager.get_debuff_data then
            local deb = buff_manager:get_debuff_data(target, spells.JOW_DEBUFF_IDS)
            jotw_missing = not (deb and deb.is_active)
        end

        if spells.judgement:is_learned()
            and spells.judgement:cooldown_up()
            and has_any_buff(player, spells.SEAL_OF_WISDOM_IDS)
            and jotw_missing then
            if spells.judgement:is_castable() then
                if spells.judgement:cast(target) then
                    return true
                end
            end
        end
    end

    auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
    return false
end

---@param player game_object
---@param menu table
---@param tick_tracker resource_ticks_tracker|nil
---@param state table|nil
function rotation_logic:execute(player, menu, tick_tracker, state)
    if not player or not menu then
        return
    end

    spells:refresh()

    local role = resolve_role(player, menu, state)

    local enemies, enemies_10 = get_enemies_around(player, 10.0, false)
    local enemies_pvp, _ = get_enemies_around(player, 25.0, true)
    local want_aoe = compute_want_aoe(enemies_10, menu, state)

    -- Safety can still be evaluated while casting/channeling (instants may save you).
    if player:is_channeling_or_casting() then
        if bool_opt(menu, state, "allow_safety_while_casting", true) then
            if try_global_safety(player, menu, enemies, state) then
                return
            end
            local target = izi.target()
            if try_pvp_overlay(player, menu, role, target, enemies_pvp, state) then
                return
            end
        end
        return
    end

    if try_global_safety(player, menu, enemies, state) then
        return
    end

    if try_maintain_buffs(player, menu, role, state) then
        return
    end

    local target = izi.target()

    if try_pvp_overlay(player, menu, role, target, enemies_pvp, state) then
        return
    end

    if role == "heal" then
        try_heal_mode(player, menu, tick_tracker, state)
        return
    end

    if role == "tank" then
        try_tank_mode(player, menu, enemies_10, want_aoe, target, state)
        return
    end

    try_dps_mode(player, menu, enemies_10, enemies, want_aoe, target, state)
end

return rotation_logic
