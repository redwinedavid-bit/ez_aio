-- ============================================================================
-- Druid Helpers - Core Module (Classic ERA)
-- Casting wrappers, buff checks, resource helpers, cooldown tracking
-- ============================================================================

local helpers = {}

---@type enums
local enums = require("common/enums")

---@type buff_manager
local buff_manager = require("common/modules/buff_manager")

local spell_data = require("rotations/druid/era/spell_data")
local auto_attack_helper = require("common/utility/auto_attack_helper")

-- ============================================================================
-- STATE
-- ============================================================================

local menu = nil
local tick_tracker = nil

-- Throttle tracking for log_checkpoint
local log_timestamps = {}
local LOG_DEFAULT_INTERVAL = 1.5

-- Cast throttle tracking (prevent double-casts)
local cast_throttle = {}
local CAST_THROTTLE_MS = 200

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

function helpers:set_menu(menu_elements)
    menu = menu_elements
    helpers._menu_elements = menu_elements
end

function helpers:set_tick_tracker(tracker)
    tick_tracker = tracker
end

function helpers:get_tick_tracker()
    return tick_tracker
end

-- ============================================================================
-- LOGGING
-- ============================================================================

function helpers:log_checkpoint(key, interval, message)
    local now = core.time()
    interval = interval or LOG_DEFAULT_INTERVAL
    local interval_ms = interval * 1000

    local last = log_timestamps[key]
    if last and (now - last) < interval_ms then
        return
    end

    log_timestamps[key] = now
    core.log(message)
end

-- Export for sub-modules
helpers._log_throttled = function(key, interval, message)
    helpers:log_checkpoint(key, interval, message)
end

-- ============================================================================
-- MENU ACCESSORS
-- ============================================================================

function helpers:get_menu()
    return menu
end

function helpers:get_spec()
    if not menu or not menu.spec_selector then return 2 end
    return menu.spec_selector:get()
end

function helpers:is_cooldowns_toggle_active()
    if not menu or not menu.cooldowns_toggle then return false end
    local ok, state = pcall(function() return menu.cooldowns_toggle:get_state() end)
    return ok and state == true
end

function helpers:is_pvp_mode()
    if not menu or not menu.pvp_toggle then return false end
    local ok, state = pcall(function() return menu.pvp_toggle:get_state() end)
    return ok and state == true
end

function helpers:is_hardcore_mode()
    if not menu or not menu.hardcore_mode then return false end
    local ok, state = pcall(function() return menu.hardcore_mode:get_state() end)
    return ok and state == true
end

function helpers:get_menu_state(element_name)
    if not menu or not menu[element_name] then return false end
    local ok, state = pcall(function() return menu[element_name]:get_state() end)
    return ok and state == true
end

function helpers:get_menu_value(element_name, default)
    if not menu or not menu[element_name] then return default or 0 end
    local ok, val = pcall(function() return menu[element_name]:get() end)
    return ok and val or (default or 0)
end

-- ============================================================================
-- SPELL CASTING
-- ============================================================================

local function is_throttled(spell_key)
    local now = core.time()
    local last = cast_throttle[spell_key]
    if last and (now - last) < CAST_THROTTLE_MS then
        return true
    end
    return false
end

local function mark_cast(spell_key)
    cast_throttle[spell_key] = core.time()
end

--- Try to cast a spell from spell_data on a target
--- @param category string Category in spell_data (e.g. "cat", "bear", "balance", etc.)
--- @param spell_key string Key within category (e.g. "claw", "maul", "wrath")
--- @param target game_object Target to cast on (can be player for self-casts)
--- @return boolean true if cast succeeded
function helpers:try_cast(category, spell_key, target)
    local cat_data = spell_data[category]
    if not cat_data then return false end

    local data = cat_data[spell_key]
    if not data or not data.spell then return false end

    local throttle_key = category .. "." .. spell_key
    if is_throttled(throttle_key) then return false end

    local ok, result = pcall(function()
        return data.spell:cast_safe(target)
    end)

    if ok and result then
        mark_cast(throttle_key)
        return true
    end

    return false
end

--- Try to cast a spell directly from a spell_data entry
--- @param data table Spell data entry with .spell field
--- @param target game_object Target
--- @param throttle_key string Optional throttle key
--- @return boolean
function helpers:try_cast_direct(data, target, throttle_key)
    if not data or not data.spell then return false end

    if throttle_key and is_throttled(throttle_key) then return false end

    local ok, result = pcall(function()
        return data.spell:cast_safe(target)
    end)

    if ok and result then
        if throttle_key then mark_cast(throttle_key) end
        return true
    end

    return false
end

-- ============================================================================
-- BUFF / DEBUFF CHECKS
-- ============================================================================

--- Check if unit has a buff by key name from spell_data.buff_ids
--- @param unit game_object
--- @param buff_key string Key in spell_data.buff_ids
--- @return boolean
function helpers:has_buff(unit, buff_key)
    if not unit then return false end
    local ids = spell_data.buff_ids[buff_key]
    if not ids then return false end

    local ok, result = pcall(function()
        return unit:buff_up(ids)
    end)

    return ok and result == true
end

--- Check if target has a debuff by key name from spell_data.debuff_ids
--- @param target game_object
--- @param debuff_key string Key in spell_data.debuff_ids
--- @return boolean
function helpers:has_debuff(target, debuff_key)
    if not target then return false end
    local ids = spell_data.debuff_ids[debuff_key]
    if not ids then return false end

    local ok, result = pcall(function()
        return target:debuff_up(ids)
    end)

    return ok and result == true
end

--- Get remaining duration of a buff on a unit
--- @param unit game_object
--- @param buff_key string Key in spell_data.buff_ids
--- @return number Remaining ms, 0 if not found
function helpers:get_buff_remaining(unit, buff_key)
    if not unit then return 0 end
    local ids = spell_data.buff_ids[buff_key]
    if not ids then return 0 end

    local ok, data = pcall(function()
        return buff_manager:get_aura_data(unit, ids, 200)
    end)

    if ok and data and data.is_active then
        return data.remaining or 0
    end
    return 0
end

--- Get remaining duration of a debuff on a target
--- @param target game_object
--- @param debuff_key string Key in spell_data.debuff_ids
--- @return number Remaining ms, 0 if not found
function helpers:get_debuff_remaining(target, debuff_key)
    if not target then return 0 end
    local ids = spell_data.debuff_ids[debuff_key]
    if not ids then return 0 end

    local ok, data = pcall(function()
        return buff_manager:get_aura_data(target, ids, 200)
    end)

    if ok and data and data.is_active then
        return data.remaining or 0
    end
    return 0
end

-- ============================================================================
-- RESOURCE HELPERS
-- ============================================================================

function helpers:get_combo_points(player)
    if not player then return 0 end
    local ok, cp = pcall(function()
        return player:get_combo_points()
    end)
    if ok and cp then return cp end

    -- Fallback: power type 4
    ok, cp = pcall(function()
        return player:get_power(4)
    end)
    return (ok and cp) or 0
end

function helpers:get_energy(player)
    if not player then return 0 end
    local ok, energy = pcall(function()
        return player:get_power(enums.power_type.ENERGY)
    end)
    return (ok and energy) or 0
end

function helpers:get_rage(player)
    if not player then return 0 end
    local ok, rage = pcall(function()
        return player:get_power(enums.power_type.RAGE)
    end)
    return (ok and rage) or 0
end

function helpers:get_mana(player)
    if not player then return 0 end
    local ok, mana = pcall(function()
        return player:get_power(enums.power_type.MANA)
    end)
    return (ok and mana) or 0
end

function helpers:get_mana_pct(player)
    if not player then return 0 end
    local ok, pct = pcall(function()
        return player:get_power_percentage(enums.power_type.MANA)
    end)
    if ok and pct then return pct end

    -- Fallback: try mana_pct method
    ok, pct = pcall(function()
        return player:mana_pct()
    end)
    return (ok and pct) or 0
end

-- ============================================================================
-- COOLDOWN CHECKS
-- ============================================================================

--- Check if a spell is off cooldown
--- @param category string Spell data category
--- @param spell_key string Spell key within category
--- @return boolean
function helpers:is_cooldown_ready(category, spell_key)
    local cat_data = spell_data[category]
    if not cat_data then return false end

    local data = cat_data[spell_key]
    if not data or not data.spell then return false end

    local ok, result = pcall(function()
        return data.spell:cooldown_up()
    end)

    return ok and result == true
end

--- Check if a spell is learned
--- @param category string Spell data category
--- @param spell_key string Spell key within category
--- @return boolean
function helpers:is_spell_learned(category, spell_key)
    local cat_data = spell_data[category]
    if not cat_data then return false end

    local data = cat_data[spell_key]
    if not data or not data.spell then return false end

    local ok, result = pcall(function()
        return data.spell:is_learned()
    end)

    return ok and result == true
end

-- ============================================================================
-- COMBAT STATE
-- ============================================================================

function helpers:is_in_combat(player)
    if not player then return false end
    local ok, result = pcall(function()
        return player:is_in_combat()
    end)
    return ok and result == true
end

function helpers:get_player_hp(player)
    if not player then return 100 end
    local ok, hp = pcall(function()
        return player:get_health_percentage()
    end)
    return (ok and hp) or 100
end

function helpers:get_unit_hp(unit)
    if not unit then return 100 end
    local ok, hp = pcall(function()
        return unit:get_health_percentage()
    end)
    return (ok and hp) or 100
end

function helpers:is_valid_enemy(target)
    if not target then return false end
    local ok, result = pcall(function()
        return target:is_valid_enemy() and target:is_alive()
    end)
    return ok and result == true
end

function helpers:is_player_casting(player)
    if not player then return false end
    local ok, casting = pcall(function()
        return player:is_casting()
    end)
    local ok2, channeling = pcall(function()
        return player:is_channeling()
    end)
    return (ok and casting) or (ok2 and channeling)
end

function helpers:is_target_casting(target)
    if not target then return false end
    local ok, result = pcall(function()
        return target:is_casting()
    end)
    return ok and result == true
end

function helpers:get_player_level(player)
    if not player then return 1 end
    local ok, level = pcall(function()
        return player:get_level()
    end)
    if ok and level then return level end

    ok, level = pcall(function()
        return player:level()
    end)
    return (ok and level) or 1
end

function helpers:ensure_auto_attack(target)
    if not target then return end
    pcall(function()
        auto_attack_helper:ensure_auto_attack(target)
    end)
end

function helpers:start_melee_attack(target)
    if not target then return end
    pcall(function()
        auto_attack_helper:start_attack(target, auto_attack_helper.ATTACK_TYPE.MELEE)
    end)
end

-- ============================================================================
-- TARGET HELPERS
-- ============================================================================

function helpers:get_target(player)
    if not player then return nil end
    local ok, target = pcall(function()
        local izi = require("common/izi_sdk")
        return izi.target()
    end)
    if ok and target and self:is_valid_enemy(target) then
        return target
    end
    return nil
end

--- Check if target is a player (for PvP detection)
function helpers:is_player_target(target)
    if not target then return false end
    local ok, result = pcall(function()
        return target:is_player()
    end)
    return ok and result == true
end

-- ============================================================================
-- DEBUFF DETECTION (for root-breaking)
-- ============================================================================

-- Common root/snare debuff IDs that druids want to break via shapeshifting
local ROOT_SNARE_DEBUFF_IDS = {
    -- Entangling Roots (enemy)
    339, 1062, 5195, 5196, 9852, 9853, 9854, 9855,
    -- Frost Nova
    122, 865, 6131, 10230,
    -- Frostbolt snare
    116, 205, 837, 7322, 8406, 8407, 10179, 10180, 25304,
    -- Hamstring
    1715, 7372, 7373, 25212,
    -- Crippling Poison
    3409,
    -- Wing Clip
    2974, 14267, 14268,
    -- Concussive Shot
    5116,
    -- Frost Trap / Frost Shock
    3600, 8056, 8058, 10472, 10473,
    -- Engineering Net
    13099,
}

function helpers:is_rooted_or_snared(player)
    if not player then return false end
    local ok, result = pcall(function()
        return player:debuff_up(ROOT_SNARE_DEBUFF_IDS)
    end)
    return ok and result == true
end

-- ============================================================================
-- SPELL DATA ACCESS
-- ============================================================================

function helpers:get_spell_data()
    return spell_data
end

function helpers:get_spell_entry(category, key)
    local cat = spell_data[category]
    if not cat then return nil end
    return cat[key]
end

-- ============================================================================
-- SUB-MODULE REGISTRATION
-- ============================================================================

local forms = require("rotations/druid/era/helpers/forms")
forms.register(helpers)

local group = require("rotations/druid/era/helpers/group")
group.register(helpers)

local consumables = require("rotations/druid/era/helpers/consumables")
consumables.register(helpers)

local racials = require("rotations/druid/era/helpers/racials")
racials.register(helpers)

return helpers
